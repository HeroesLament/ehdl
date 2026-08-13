# Nervezynq.WFTap — waterfall tap: snapshot captures over TCP to the host GUI.
#
# Hot-loadable like sdr.exs, and depends on it:
#
#     Code.compile_file("/data/sdr.exs")
#     Code.compile_file("/data/wf_tap.exs")
#     {:ok, _} = Nervezynq.SDR.open()        # or your own open() args
#     Nervezynq.WFTap.start()                # listens on 7355
#
# Then on the Mac: `NzScope.Link.connect("192.168.217.58")` (scope app).
#
# ## Protocol (both ends are BEAM, both ends are ours)
#
# TCP, `{:packet, 4}` framing, `:erlang.term_to_binary/1` payloads.
#
# Board → host:
#   {:hello,  %{fs:, freq:, gain:, n:, interval_ms:}}
#   {:iq,     %{seq:, fs:, freq:, gain:, n:}, iq_binary}   # rx_binary/1 ch1
#   {:status, map}                                          # SDR.status/0 + tap state
#   {:error,  term}                                         # a capture or command failed
#
# Host → board:
#   {:retune, hz} | {:gain, db} | {:pause, bool} | {:nsamples, n}
#   | {:interval, ms} | {:mode, :snapshot | :stream} | :status
#
# ## Two row sources, one wire format
#
# :snapshot (default) — LVDSProbe capture via SDR.rx_binary/1: gapless
# within ~1020 pairs, dead time between. Works on every bitstream.
#
# :stream — the HP0 DMA ring (hp_dma_s1+ bitstream, hp_stream.exs loaded):
# each row is the NEWEST n frames out of the ring, decoded board-side to
# the same interleaved s16 ch1 binary, so NzScope.Link changes not at all.
# Row rate is poll rate; the stream itself runs gapless at full sample
# rate into DDR underneath. Deliberately decimated — the waterfall needs
# ~30 rows/s, and usb0 could not carry the full stream anyway (64 MB/s at
# 8 Msps). Meta gains :seq_holes (0 = row internally gapless) and
# :stream? so the host can tell rows apart.
#
# One client at a time. A second connect while one is live gets accepted
# when the first drops. No auth — this listens on usb0/eth0 on a bench
# board; if that stops being true, revisit.

defmodule Nervezynq.WFTap do
  @moduledoc "Snapshot-capture waterfall tap. See file header."

  require Logger

  @default_port 7355
  @default_n 1020
  @default_interval_ms 50

  @doc """
  Start the tap listener. Options: `:port`, `:n` (pairs per capture),
  `:interval_ms` (sleep between captures; captures themselves take time on
  top of this). Idempotent-ish: a second start returns the running pid.
  """
  def start(opts \\ []) do
    case Process.whereis(__MODULE__) do
      nil ->
        pid = spawn(fn -> listen(opts) end)
        Process.register(pid, __MODULE__)
        {:ok, pid}

      pid ->
        {:ok, pid}
    end
  end

  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  # --- listener ----------------------------------------------------------------

  defp listen(opts) do
    port = Keyword.get(opts, :port, @default_port)

    {:ok, lsock} =
      :gen_tcp.listen(port, [
        :binary,
        packet: 4,
        active: false,
        reuseaddr: true,
        nodelay: true
      ])

    Logger.info("WFTap: listening on #{port}")
    accept_loop(lsock, opts)
  end

  defp accept_loop(lsock, opts) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    :inet.setopts(sock, active: true)
    Logger.info("WFTap: client connected")

    st = %{
      sock: sock,
      seq: 0,
      n: Keyword.get(opts, :n, @default_n),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      paused: false,
      mode: Keyword.get(opts, :mode, :snapshot)
    }

    send_term(sock, {:hello, hello_meta(st)})
    serve(st)

    Logger.info("WFTap: client gone")
    accept_loop(lsock, opts)
  end

  # --- serve loop ---------------------------------------------------------------
  # One loop, one socket, mailbox-driven commands between captures.

  defp serve(st) do
    case drain_commands(st) do
      :closed ->
        :ok

      st ->
        st =
          if st.paused do
            Process.sleep(50)
            st
          else
            st = capture_and_send(st)
            Process.sleep(st.interval_ms)
            st
          end

        serve(st)
    end
  end

  defp drain_commands(st) do
    receive do
      {:tcp, _sock, bin} ->
        case decode(bin) do
          {:ok, cmd} ->
            case handle_command(cmd, st) do
              %{} = st2 -> drain_commands(st2)
            end

          :error ->
            send_term(st.sock, {:error, :bad_command})
            drain_commands(st)
        end

      {:tcp_closed, _sock} ->
        :closed

      {:tcp_error, _sock, _reason} ->
        :closed
    after
      0 -> st
    end
  end

  defp capture_and_send(st) do
    case grab_row(st) do
      {:ok, iq, extra} ->
        meta =
          Map.merge(
            %{
              seq: st.seq,
              fs: Nervezynq.SDR.sample_rate(),
              freq: Nervezynq.SDR.frequency(),
              gain: quiet(fn -> Agent.get(Nervezynq.SDR.State, & &1.gain_db) end),
              n: div(byte_size(iq), 4)
            },
            extra
          )

        send_term(st.sock, {:iq, meta, iq})
        %{st | seq: st.seq + 1}

      error ->
        send_term(st.sock, {:error, {:capture, error}})
        # Back off rather than machine-gunning a broken capture path.
        Process.sleep(500)
        st
    end
  end

  defp grab_row(%{mode: :snapshot} = st) do
    with {:ok, iq} <- Nervezynq.SDR.rx_binary(st.n), do: {:ok, iq, %{stream?: false}}
  end

  defp grab_row(%{mode: :stream} = st) do
    # Newest st.n frames out of the DMA ring, decoded board-side to the same
    # interleaved s16 ch1 binary the snapshot path ships. One frame = one
    # ch1 pair, so a stream row is a straight n-for-n replacement.
    alias Nervezynq.HPStream

    bytes = st.n * 8
    ring = 0x0010_0000
    win_end = rem(HPStream.wptr_offset() - 64 + ring, ring)
    win_start = rem(win_end - bytes + ring, ring)

    first = min(bytes, ring - win_start)
    {:ok, a} = HPStream.ring_read(win_start, div(first, 4))

    words =
      if first == bytes do
        a
      else
        {:ok, b} = HPStream.ring_read(0, div(bytes - first, 4))
        a ++ b
      end

    u64 = HPStream.to_u64(words)
    seq_check = HPStream.check_seq(u64)

    iq =
      for w <- u64, into: <<>> do
        d = HPStream.decode_word(w)
        {i, q} = d.ch1
        <<i::little-signed-16, q::little-signed-16>>
      end

    {:ok, iq, %{stream?: true, seq_holes: seq_check.holes}}
  rescue
    e -> {:error, e}
  end

  defp handle_command({:retune, hz}, st) when is_integer(hz) do
    reply_status(st, fn -> Nervezynq.SDR.set_frequency(hz) end)
  end

  defp handle_command({:gain, db}, st) when is_number(db) do
    reply_status(st, fn -> Nervezynq.SDR.set_gain(db) end)
  end

  defp handle_command({:pause, flag}, st) when is_boolean(flag), do: %{st | paused: flag}

  defp handle_command({:nsamples, n}, st) when is_integer(n) and n > 0,
    do: %{st | n: min(n, 1020)}

  defp handle_command({:interval, ms}, st) when is_integer(ms) and ms >= 0,
    do: %{st | interval_ms: ms}

  defp handle_command({:mode, :stream}, st) do
    # Bring the DMA stream up; fall back to snapshot with an error if the
    # stream stack is not loaded or the bitstream lacks the radio producer.
    case quiet(fn ->
           Nervezynq.HPStream.setup()
           Nervezynq.HPStream.disable()
           Nervezynq.HPStream.select(:radio)
           Nervezynq.HPStream.clear_flags()
           Nervezynq.HPStream.enable()
           :ok
         end) do
      :ok ->
        %{st | mode: :stream}

      _ ->
        send_term(st.sock, {:error, {:stream_unavailable, :hp_stream}})
        st
    end
  end

  defp handle_command({:mode, :snapshot}, st) do
    quiet(fn -> Nervezynq.HPStream.disable() end)
    %{st | mode: :snapshot}
  end

  defp handle_command(:status, st) do
    send_term(st.sock, {:status, safe_status(st)})
    st
  end

  defp handle_command(other, st) do
    send_term(st.sock, {:error, {:unknown_command, other}})
    st
  end

  defp reply_status(st, fun) do
    case quiet(fun) do
      {:ok, _} = ok ->
        send_term(st.sock, {:status, Map.put(safe_status(st), :last_command, ok)})

      other ->
        send_term(st.sock, {:error, {:command_failed, other}})
    end

    st
  end

  defp safe_status(st) do
    base = quiet(fn -> Nervezynq.SDR.status() end) || %{}

    Map.merge(base, %{
      tap: %{n: st.n, interval_ms: st.interval_ms, paused: st.paused, seq: st.seq, mode: st.mode}
    })
  end

  defp hello_meta(st) do
    %{
      fs: quiet(fn -> Nervezynq.SDR.sample_rate() end),
      freq: quiet(fn -> Nervezynq.SDR.frequency() end),
      gain: quiet(fn -> Agent.get(Nervezynq.SDR.State, & &1.gain_db) end),
      n: st.n,
      interval_ms: st.interval_ms
    }
  end

  # --- plumbing -----------------------------------------------------------------

  defp send_term(sock, term), do: :gen_tcp.send(sock, :erlang.term_to_binary(term))

  defp decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  defp quiet(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end
end
