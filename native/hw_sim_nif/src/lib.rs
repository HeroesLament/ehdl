use rustler::{Encoder, Env, Error, NifResult, ResourceArc, Term};
use rustler::types::atom::Atom;
use rustler::types::tuple::make_tuple;
use std::collections::HashMap;
use std::sync::Mutex;

rustler::atoms! { ok, error, }

// ---------------------------------------------------------------------------
// Bytecode instruction format
//
// Each instruction is a packed u64:
//   [63:56] opcode   (u8)
//   [55:40] out      (u16) — index into state vec
//   [39:24] a        (u16) — signal index or const table index
//   [23:8]  b        (u16) — signal index or const table index
//   [7:2]   w        (u6)  — output width (0 = 64)
//   [1]     b_is_const
//   [0]     a_is_const
//
// For ops that don't fit (Mux, Concat, Slice, RegNext), we use an
// extended instruction that stores an index into the `ext` table.
// ---------------------------------------------------------------------------

const OP_ASSIGN:      u8 = 0;
const OP_ADD:         u8 = 1;
const OP_SUB:         u8 = 2;
const OP_MUL:         u8 = 3;
const OP_DIV:         u8 = 4;
const OP_MOD:         u8 = 5;
const OP_NEG:         u8 = 6;
const OP_ABS:         u8 = 7;
const OP_MIN:         u8 = 8;
const OP_MAX:         u8 = 9;
const OP_BITAND:      u8 = 10;
const OP_BITOR:       u8 = 11;
const OP_BITXOR:      u8 = 12;
const OP_BITNOT:      u8 = 13;
const OP_SHL:         u8 = 14;
const OP_SHR:         u8 = 15;
const OP_SHRA:        u8 = 16;
const OP_REDUCE_AND:  u8 = 17;
const OP_REDUCE_OR:   u8 = 18;
const OP_REDUCE_XOR:  u8 = 19;
const OP_REPLICATE:   u8 = 20;
const OP_CAST:        u8 = 21;
const OP_EQ:          u8 = 22;
const OP_NEQ:         u8 = 23;
const OP_LT:          u8 = 24;
const OP_GT:          u8 = 25;
const OP_LTE:         u8 = 26;
const OP_GTE:         u8 = 27;
const OP_SLICE:       u8 = 28;  // b = lo, w = hi-lo+1
const OP_EXT:         u8 = 29;  // extended — a field = ext table index
const OP_REG_NEXT:    u8 = 30;  // extended

#[inline(always)]
fn pack(opcode: u8, out: u16, a: u16, b: u16, w: u8, a_const: bool, b_const: bool) -> u64 {
    ((opcode as u64) << 56)
    | ((out as u64) << 40)
    | ((a   as u64) << 24)
    | ((b   as u64) << 8)
    | ((w.min(63) as u64) << 2)
    | ((b_const as u64) << 1)
    | (a_const as u64)
}

#[inline(always)] fn instr_op(i: u64)      -> u8  { (i >> 56) as u8 }
#[inline(always)] fn instr_out(i: u64)     -> u16 { ((i >> 40) & 0xffff) as u16 }
#[inline(always)] fn instr_a(i: u64)       -> u16 { ((i >> 24) & 0xffff) as u16 }
#[inline(always)] fn instr_b(i: u64)       -> u16 { ((i >>  8) & 0xffff) as u16 }
#[inline(always)] fn instr_w(i: u64)       -> u8  { let w = ((i >> 2) & 0x3f) as u8; if w == 0 { 64 } else { w } }
#[inline(always)] fn instr_b_const(i: u64) -> bool { (i & 2) != 0 }
#[inline(always)] fn instr_a_const(i: u64) -> bool { (i & 1) != 0 }

// Extended ops that don't fit in the packed format
#[derive(Clone)]
enum ExtOp {
    Concat { out: u16, w: u8, inputs: Vec<(u16, bool, u8)> }, // (idx, is_const, width)
    Mux    { out: u16, w: u8, cases: Vec<(u16, bool, u16, bool)>, default_idx: u16, default_const: bool },
}

// RegNext stored separately (only evaluated in phase 1)
#[derive(Clone)]
struct RegNextOp {
    out:          u16,
    w:            u8,
    input:        u16,
    input_const:  bool,
    enable:       Option<u16>,
    reset_val:    u64,
    async_reset:  Option<u16>,
}

// ---------------------------------------------------------------------------
// Automaton
// ---------------------------------------------------------------------------

pub struct Automaton {
    state:       Vec<u64>,
    name_to_idx: HashMap<String, u32>,
    idx_to_name: Vec<String>,
    consts:      Vec<u64>,
    comb_bc:     Vec<Vec<u64>>,
    ext_ops:     Vec<Vec<ExtOp>>,
    reg_ops:     Vec<Vec<RegNextOp>>,
    reg_scratch: Vec<(u16, u64)>,
    // Per-clock data stored as parallel vecs for cache-friendly tick access
    clock_names:          Vec<String>,
    clock_half_periods:   Vec<u64>,
    clock_entity_indices: Vec<Vec<usize>>,
    cross_bc_per_clock:   Vec<Vec<u64>>,
    cross_ext_per_clock:  Vec<Vec<ExtOp>>,
    time_ps: u64,
}

pub struct AutomatonResource(pub Mutex<Automaton>);

// ---------------------------------------------------------------------------
// Execution helpers
// ---------------------------------------------------------------------------

#[inline(always)]
fn mask(val: u64, w: u8) -> u64 {
    if w >= 64 { val } else { val & ((1u64 << w).wrapping_sub(1)) }
}

#[inline(always)]
fn rd(idx: u16, is_const: bool, state: &[u64], consts: &[u64]) -> u64 {
    if is_const { consts[idx as usize] } else { state[idx as usize] }
}

#[inline(never)]
fn run_bc(bc: &[u64], ext: &[ExtOp], state: &mut Vec<u64>, consts: &[u64]) {
    for &instr in bc {
        let op  = instr_op(instr);
        let out = instr_out(instr) as usize;
        let ai  = instr_a(instr);
        let bi  = instr_b(instr);
        let w   = instr_w(instr);
        let ac  = instr_a_const(instr);
        let bc_ = instr_b_const(instr);

        let a = rd(ai, ac, state, consts);
        let b = rd(bi, bc_, state, consts);

        state[out] = match op {
            OP_ASSIGN     => a,
            OP_ADD        => mask(a.wrapping_add(b), w),
            OP_SUB        => mask(a.wrapping_sub(b), w),
            OP_MUL        => mask(a.wrapping_mul(b), w),
            OP_DIV        => if b == 0 { 0 } else { mask(a / b, w) },
            OP_MOD        => if b == 0 { 0 } else { mask(a % b, w) },
            OP_NEG        => mask(a.wrapping_neg(), w),
            OP_ABS        => mask((a as i64).unsigned_abs(), w),
            OP_MIN        => mask(a.min(b), w),
            OP_MAX        => mask(a.max(b), w),
            OP_BITAND     => mask(a & b, w),
            OP_BITOR      => mask(a | b, w),
            OP_BITXOR     => mask(a ^ b, w),
            OP_BITNOT     => mask(a ^ mask(u64::MAX, w), w),
            OP_SHL        => mask(a.wrapping_shl(b as u32), w),
            OP_SHR        => mask(a.wrapping_shr(b as u32), w),
            OP_SHRA       => {
                let sign = (a >> (w as u32 - 1)) & 1;
                let sh = b as u32;
                if sign == 1 && sh > 0 {
                    let fill = ((1u64 << sh) - 1) << (w as u32 - sh);
                    mask((a >> sh) | fill, w)
                } else { mask(a >> sh, w) }
            }
            OP_REDUCE_AND => if a == mask(u64::MAX, w) { 1 } else { 0 },
            OP_REDUCE_OR  => if a != 0 { 1 } else { 0 },
            OP_REDUCE_XOR => a.count_ones() as u64 & 1,
            OP_REPLICATE  => {
                let n = b as u32;
                let bw = if n > 0 { w as u32 / n } else { w as u32 };
                mask((0..n).fold(0u64, |acc, i| acc | (a << (i * bw))), w)
            }
            OP_CAST       => mask(a, w),
            OP_EQ         => if a == b { 1 } else { 0 },
            OP_NEQ        => if a != b { 1 } else { 0 },
            OP_LT         => if a < b { 1 } else { 0 },
            OP_GT         => if a > b { 1 } else { 0 },
            OP_LTE        => if a <= b { 1 } else { 0 },
            OP_GTE        => if a >= b { 1 } else { 0 },
            OP_SLICE      => {
                let lo = b as u32;
                mask(a >> lo, w)
            }
            OP_EXT => {
                let ext_i = if ac { consts[ai as usize] as usize } else { ai as usize };
                if ext_i < ext.len() {
                    run_ext(&ext[ext_i], state, consts);
                }
                continue;
            }
            _ => 0,
        };
    }
}

fn run_ext(op: &ExtOp, state: &mut Vec<u64>, consts: &[u64]) {
    match op {
        ExtOp::Concat { out, w, inputs } => {
            let mut result = 0u64;
            let mut shift = 0u32;
            for &(idx, is_const, iw) in inputs.iter().rev() {
                result |= rd(idx, is_const, state, consts) << shift;
                shift += iw as u32;
            }
            state[*out as usize] = mask(result, *w);
        }
        ExtOp::Mux { out, w, cases, default_idx, default_const } => {
            let val = cases.iter().find_map(|&(ci, cc, vi, vc)| {
                if rd(ci, cc, state, consts) != 0 { Some(rd(vi, vc, state, consts)) } else { None }
            }).unwrap_or_else(|| rd(*default_idx, *default_const, state, consts));
            state[*out as usize] = mask(val, *w);
        }
    }
}

// ---------------------------------------------------------------------------
// Tick
// ---------------------------------------------------------------------------

impl Automaton {
    fn clock_idx(&self, name: &str) -> Option<usize> {
        self.clock_names.iter().position(|n| n == name)
    }

    fn tick_n(&mut self, clock_name: &str, n: u64) -> Vec<(u64, u32, u64, u64)> {
        let ci = match self.clock_idx(clock_name) {
            Some(i) => i,
            None    => return vec![],
        };
        let half_ps    = self.clock_half_periods[ci];
        let n_entities = self.clock_entity_indices[ci].len();
        let mut changes = Vec::new();

        for _ in 0..n {
            self.time_ps += half_ps;
            self.reg_scratch.clear();

            // Phase 1: comb eval + reg_next
            for i in 0..n_entities {
                let ei = self.clock_entity_indices[ci][i];
                {
                    let bc  = &self.comb_bc[ei]  as *const Vec<u64>;
                    let ext = &self.ext_ops[ei]  as *const Vec<ExtOp>;
                    unsafe { run_bc(&*bc, &*ext, &mut self.state, &self.consts); }
                }
                for r in &self.reg_ops[ei] {
                    let next = if let Some(ar) = r.async_reset {
                        if self.state[ar as usize] != 0 { r.reset_val }
                        else { reg_next_val(r, &self.state, &self.consts) }
                    } else {
                        reg_next_val(r, &self.state, &self.consts)
                    };
                    self.reg_scratch.push((r.out, mask(next, r.w)));
                }
            }

            // Phase 2: latch regs
            for &(idx, next) in &self.reg_scratch {
                let old = self.state[idx as usize];
                if old != next { changes.push((self.time_ps, idx as u32, old, next)); }
                self.state[idx as usize] = next;
            }

            // Phase 3: re-eval comb + cross-settle
            for i in 0..n_entities {
                let ei = self.clock_entity_indices[ci][i];
                let bc  = &self.comb_bc[ei]  as *const Vec<u64>;
                let ext = &self.ext_ops[ei]  as *const Vec<ExtOp>;
                unsafe { run_bc(&*bc, &*ext, &mut self.state, &self.consts); }
            }
            {
                let bc  = &self.cross_bc_per_clock[ci]  as *const Vec<u64>;
                let ext = &self.cross_ext_per_clock[ci] as *const Vec<ExtOp>;
                unsafe { run_bc(&*bc, &*ext, &mut self.state, &self.consts); }
            }

            self.time_ps += half_ps;
        }
        changes
    }
}

#[inline(always)]
fn reg_next_val(r: &RegNextOp, state: &[u64], consts: &[u64]) -> u64 {
    if let Some(en) = r.enable {
        if state[en as usize] == 0 { return state[r.out as usize]; }
    }
    mask(rd(r.input, r.input_const, state, consts), r.w)
}

// ---------------------------------------------------------------------------
// Decode helpers — build bytecode from Elixir terms
// ---------------------------------------------------------------------------

fn atom_str<'a>(a: Atom, env: Env<'a>) -> NifResult<String> {
    a.to_term(env).atom_to_string().map_err(|_| Error::BadArg)
}

fn term_map_to_hash<'a>(env: Env<'a>, map: Term<'a>) -> NifResult<HashMap<String, Term<'a>>> {
    let iter: rustler::MapIterator = map.decode().map_err(|_| Error::BadArg)?;
    let mut h = HashMap::new();
    for (k, v) in iter {
        if let Ok(ka) = k.decode::<Atom>() {
            if let Ok(s) = atom_str(ka, env) {
                h.insert(s, v);
            }
        }
    }
    Ok(h)
}

fn get_map_key<'a>(env: Env<'a>, map: Term<'a>, key: &str) -> NifResult<Term<'a>> {
    let iter: rustler::MapIterator = map.decode().map_err(|_| Error::BadArg)?;
    for (k, v) in iter {
        if let Ok(ka) = k.decode::<Atom>() {
            if let Ok(s) = atom_str(ka, env) {
                if s == key { return Ok(v); }
            }
        }
    }
    Err(Error::BadArg)
}

struct Builder<'a, 'e> {
    n2i:    &'a HashMap<String, u32>,
    consts: &'a mut Vec<u64>,
    env:    Env<'e>,
}

impl<'a, 'e> Builder<'a, 'e> {
    fn const_idx(&mut self, v: u64) -> u16 {
        if let Some(i) = self.consts.iter().position(|&x| x == v) {
            i as u16
        } else {
            let i = self.consts.len() as u16;
            self.consts.push(v);
            i
        }
    }

    fn operand(&mut self, t: Term) -> NifResult<(u16, bool)> {
        if t.is_atom() { return Ok((self.const_idx(0), true)); }
        let elems = rustler::types::tuple::get_tuple(t).map_err(|_| Error::BadArg)?;
        if elems.len() < 2 { return Ok((self.const_idx(0), true)); }
        let tag: Atom = elems[0].decode()?;
        match atom_str(tag, self.env)?.as_str() {
            "signal" => {
                let a: Atom = elems[1].decode()?;
                let name = atom_str(a, self.env)?;
                let idx = self.n2i.get(&name).copied().ok_or(Error::BadArg)?;
                Ok((idx as u16, false))
            }
            "const" => {
                let v: u64 = elems[1].decode()?;
                Ok((self.const_idx(v), true))
            }
            _ => Ok((self.const_idx(0), true)),
        }
    }
}

fn decode_ops_to_bc<'a>(
    env: Env<'a>,
    comb_ts: &[Term<'a>],
    rn_ts:   &[Term<'a>],
    n2i:     &HashMap<String, u32>,
    consts:  &mut Vec<u64>,
) -> NifResult<(Vec<u64>, Vec<ExtOp>, Vec<RegNextOp>)> {
    let mut bc:      Vec<u64>       = Vec::new();
    let mut ext:     Vec<ExtOp>     = Vec::new();
    let mut reg_ops: Vec<RegNextOp> = Vec::new();
    let mut b = Builder { n2i, consts, env };

    for &t in comb_ts {
        let m = term_map_to_hash(env, t)?;

        let ts = match m.get("op") {
            Some(v) => { let a: Atom = v.decode()?; atom_str(a, env)? }
            None => continue,
        };

        let out: u16 = match m.get("out") {
            Some(v) => { let a: Atom = v.decode()?; *b.n2i.get(&atom_str(a, env)?).ok_or(Error::BadArg)? as u16 }
            None => continue,
        };
        let w: u8 = m.get("w").and_then(|v| { let n: u64 = v.decode().ok()?; Some(n.min(63) as u8) }).unwrap_or(1);

        let mut go = |key: &str| -> NifResult<(u16, bool)> {
            b.operand(*m.get(key).ok_or(Error::BadArg)?)
        };

        macro_rules! ab { () => {{ let a=go("a")?; let bv=go("b")?; (a.0,a.1,bv.0,bv.1) }}; }
        macro_rules! ao { () => { go("a")? }; }

        match ts.as_str() {
            "assign"     => { let (ai,ac)=ao!(); bc.push(pack(OP_ASSIGN,   out,ai,0,w,ac,false)); }
            "add"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_ADD,    out,ai,bi,w,ac,bc_)); }
            "sub"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_SUB,    out,ai,bi,w,ac,bc_)); }
            "mul"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_MUL,    out,ai,bi,w,ac,bc_)); }
            "div"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_DIV,    out,ai,bi,w,ac,bc_)); }
            "mod"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_MOD,    out,ai,bi,w,ac,bc_)); }
            "neg"        => { let (ai,ac)=ao!(); bc.push(pack(OP_NEG,    out,ai,0,w,ac,false)); }
            "abs"        => { let (ai,ac)=ao!(); bc.push(pack(OP_ABS,    out,ai,0,w,ac,false)); }
            "min"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_MIN,    out,ai,bi,w,ac,bc_)); }
            "max"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_MAX,    out,ai,bi,w,ac,bc_)); }
            "bit_and"    => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_BITAND, out,ai,bi,w,ac,bc_)); }
            "bit_or"     => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_BITOR,  out,ai,bi,w,ac,bc_)); }
            "bit_xor"    => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_BITXOR, out,ai,bi,w,ac,bc_)); }
            "bit_not"    => { let (ai,ac)=ao!(); bc.push(pack(OP_BITNOT,  out,ai,0,w,ac,false)); }
            "shl"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_SHL,    out,ai,bi,w,ac,bc_)); }
            "shr"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_SHR,    out,ai,bi,w,ac,bc_)); }
            "shra"       => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_SHRA,   out,ai,bi,w,ac,bc_)); }
            "reduce_and" => { let (ai,ac)=ao!(); bc.push(pack(OP_REDUCE_AND, out,ai,0,w,ac,false)); }
            "reduce_or"  => { let (ai,ac)=ao!(); bc.push(pack(OP_REDUCE_OR,  out,ai,0,1,ac,false)); }
            "reduce_xor" => { let (ai,ac)=ao!(); bc.push(pack(OP_REDUCE_XOR, out,ai,0,1,ac,false)); }
            "replicate"  => { let (ai,ac)=ao!(); let (bi,bc_)=go("count")?; bc.push(pack(OP_REPLICATE,out,ai,bi,w,ac,bc_)); }
            "cast"       => { let (ai,ac)=ao!(); bc.push(pack(OP_CAST,   out,ai,0,w,ac,false)); }
            "eq"         => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_EQ,  out,ai,bi,1,ac,bc_)); }
            "neq"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_NEQ, out,ai,bi,1,ac,bc_)); }
            "lt"         => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_LT,  out,ai,bi,1,ac,bc_)); }
            "gt"         => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_GT,  out,ai,bi,1,ac,bc_)); }
            "lte"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_LTE, out,ai,bi,1,ac,bc_)); }
            "gte"        => { let (ai,ac,bi,bc_)=ab!(); bc.push(pack(OP_GTE, out,ai,bi,1,ac,bc_)); }
            "slice"      => {
                let (ai,ac) = ao!();
                let lo: u64 = m.get("lo").ok_or(Error::BadArg)?.decode()?;
                let lo_idx = b.const_idx(lo);
                bc.push(pack(OP_SLICE, out, ai, lo_idx, w, ac, true));
            }
            "concat" => {
                let its: Vec<Term> = m.get("inputs").ok_or(Error::BadArg)?.decode()?;
                let inputs = its.iter().map(|t| {
                    let elems = rustler::types::tuple::get_tuple(*t).map_err(|_|Error::BadArg)?;
                    let iw: u64 = elems[1].decode()?;
                    let (idx, ic) = b.operand(elems[0])?;
                    Ok((idx, ic, iw as u8))
                }).collect::<NifResult<Vec<_>>>()?;
                let ext_i = b.const_idx(ext.len() as u64);
                bc.push(pack(OP_EXT, 0, ext_i, 0, 0, true, false));
                ext.push(ExtOp::Concat { out, w, inputs });
            }
            "mux" => {
                let cts: Vec<Term> = m.get("cases").ok_or(Error::BadArg)?.decode()?;
                let cases = cts.iter().map(|t| {
                    let elems = rustler::types::tuple::get_tuple(*t).map_err(|_|Error::BadArg)?;
                    let (ci,cc) = b.operand(elems[0])?;
                    let (vi,vc) = b.operand(elems[1])?;
                    Ok((ci,cc,vi,vc))
                }).collect::<NifResult<Vec<_>>>()?;
                let (di,dc) = b.operand(*m.get("default").ok_or(Error::BadArg)?)?;
                let ext_i = b.const_idx(ext.len() as u64);
                bc.push(pack(OP_EXT, 0, ext_i, 0, 0, true, false));
                ext.push(ExtOp::Mux { out, w, cases, default_idx: di, default_const: dc });
            }
            _ => {}
        }
    }

    // Decode reg_next ops
    for &t in rn_ts {
        let m = term_map_to_hash(env, t)?;
        let out_atom: Atom = m.get("out").ok_or(Error::BadArg)?.decode()?;
        let out = *b.n2i.get(&atom_str(out_atom, env)?).ok_or(Error::BadArg)? as u16;
        let w: u8 = m.get("w").and_then(|v| { let n: u64 = v.decode().ok()?; Some(n.min(63) as u8) }).unwrap_or(1);
        let (input, input_const) = b.operand(*m.get("a").ok_or(Error::BadArg)?)?;
        let reset_val: u64 = m.get("reset_val").and_then(|v| v.decode().ok()).unwrap_or(0);
        let enable = m.get("enable").and_then(|v| {
            if v.is_atom() { return None; }
            b.operand(*v).ok().and_then(|(idx, ic)| if ic { None } else { Some(idx) })
        });
        let async_reset = m.get("async_reset").and_then(|v| {
            if v.is_atom() { return None; }
            b.operand(*v).ok().and_then(|(idx, ic)| if ic { None } else { Some(idx) })
        });
        reg_ops.push(RegNextOp { out, w, input, input_const, enable, reset_val, async_reset });
    }

    Ok((bc, ext, reg_ops))
}

// ---------------------------------------------------------------------------
// NIF functions
// ---------------------------------------------------------------------------

#[rustler::nif]
fn compile<'a>(env: Env<'a>, schedule: Term<'a>) -> NifResult<Term<'a>> {
    let sigs: Vec<Term> = get_map_key(env, schedule, "signals")?.decode()?;
    let mut n2i: HashMap<String, u32> = HashMap::new();
    let mut idx_to_name: Vec<String> = Vec::new();
    let mut state: Vec<u64> = Vec::new();

    for s in &sigs {
        let elems = rustler::types::tuple::get_tuple(*s).map_err(|_|Error::BadArg)?;
        let name_a: Atom = elems[0].decode()?;
        let _w: u64 = elems[1].decode()?;
        let init: u64 = elems[2].decode()?;
        let name = atom_str(name_a, env)?;
        n2i.insert(name.clone(), n2i.len() as u32);
        idx_to_name.push(name);
        state.push(init);
    }

    let mut consts: Vec<u64> = vec![0]; // index 0 = zero const
    let mut comb_bc:  Vec<Vec<u64>>       = Vec::new();
    let mut ext_ops:  Vec<Vec<ExtOp>>     = Vec::new();
    let mut reg_ops_all: Vec<Vec<RegNextOp>> = Vec::new();
    let mut total_regs = 0usize;

    let ents: Vec<Term> = get_map_key(env, schedule, "entities")?.decode()?;
    for e in &ents {
        let elems = rustler::types::tuple::get_tuple(*e).map_err(|_|Error::BadArg)?;
        let comb_ts: Vec<Term> = match elems[2].decode() { Ok(v) => v, Err(_) => return Err(Error::BadArg) };
        let rn_ts:   Vec<Term> = match elems[3].decode() { Ok(v) => v, Err(_) => return Err(Error::BadArg) };
        let (bc, ext, regs) = decode_ops_to_bc(env, &comb_ts, &rn_ts, &n2i, &mut consts)?;
        total_regs += regs.len();
        comb_bc.push(bc);
        ext_ops.push(ext);
        reg_ops_all.push(regs);
    }

    let mut clock_names:          Vec<String>     = Vec::new();
    let mut clock_half_periods:   Vec<u64>        = Vec::new();
    let mut clock_entity_indices: Vec<Vec<usize>> = Vec::new();
    let mut cross_bc_per_clock:   Vec<Vec<u64>>   = Vec::new();
    let mut cross_ext_per_clock:  Vec<Vec<ExtOp>> = Vec::new();

    let clks: Vec<Term> = get_map_key(env, schedule, "clocks")?.decode()?;
    for c in &clks {
        let elems = rustler::types::tuple::get_tuple(*c).map_err(|_|Error::BadArg)?;
        let name_a: Atom = elems[0].decode()?;
        let period_ps: u64 = elems[1].decode()?;
        let ei_list: Vec<usize> = elems[2].decode()?;
        let cs_ts: Vec<Term> = match elems[3].decode() { Ok(v) => v, Err(_) => return Err(Error::BadArg) };
        let name = atom_str(name_a, env)?;
        let (cbc, cext, _) = decode_ops_to_bc(env, &cs_ts, &[], &n2i, &mut consts)?;
        clock_names.push(name);
        clock_half_periods.push(period_ps / 2);
        clock_entity_indices.push(ei_list);
        cross_bc_per_clock.push(cbc);
        cross_ext_per_clock.push(cext);
    }

    let reg_scratch = Vec::with_capacity(total_regs);

    let automaton = Automaton {
        state, name_to_idx: n2i, idx_to_name, consts,
        comb_bc, ext_ops, reg_ops: reg_ops_all, reg_scratch,
        clock_names, clock_half_periods, clock_entity_indices,
        cross_bc_per_clock, cross_ext_per_clock,
        time_ps: 0,
    };
    let resource = ResourceArc::new(AutomatonResource(Mutex::new(automaton)));
    let ok_atom = ok().to_term(env);
    Ok(make_tuple(env, &[ok_atom, resource.encode(env)]))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn tick<'a>(env: Env<'a>, resource: ResourceArc<AutomatonResource>, clock_name: Atom, n: u64) -> NifResult<Term<'a>> {
    let name = atom_str(clock_name, env)?;
    let mut auto = resource.0.lock().map_err(|_| Error::BadArg)?;
    let changes = auto.tick_n(&name, n);
    let change_terms: Vec<Term> = changes.iter().map(|(t, idx, old, new)| {
        let na = Atom::from_str(env, &auto.idx_to_name[*idx as usize])
            .map(|a| a.to_term(env)).unwrap_or_else(|_| ok().to_term(env));
        make_tuple(env, &[t.encode(env), na, old.encode(env), new.encode(env)])
    }).collect();
    let ok_atom = ok().to_term(env);
    Ok(make_tuple(env, &[ok_atom, change_terms.encode(env)]))
}

#[rustler::nif]
fn get_signal<'a>(env: Env<'a>, resource: ResourceArc<AutomatonResource>, name: Atom) -> NifResult<Term<'a>> {
    let s = atom_str(name, env)?;
    let auto = resource.0.lock().map_err(|_| Error::BadArg)?;
    let idx = *auto.name_to_idx.get(&s).ok_or(Error::BadArg)?;
    Ok(make_tuple(env, &[ok().to_term(env), auto.state[idx as usize].encode(env)]))
}

#[rustler::nif]
fn set_signal<'a>(env: Env<'a>, resource: ResourceArc<AutomatonResource>, name: Atom, value: u64) -> NifResult<Term<'a>> {
    let s = atom_str(name, env)?;
    let mut auto = resource.0.lock().map_err(|_| Error::BadArg)?;
    let idx = *auto.name_to_idx.get(&s).ok_or(Error::BadArg)? as usize;
    auto.state[idx] = value;
    Ok(ok().to_term(env))
}

#[rustler::nif]
fn get_time<'a>(env: Env<'a>, resource: ResourceArc<AutomatonResource>) -> NifResult<Term<'a>> {
    let auto = resource.0.lock().map_err(|_| Error::BadArg)?;
    Ok(auto.time_ps.encode(env))
}

rustler::init!(
    "Elixir.Hw.Sim.Nif",
    [compile, tick, get_signal, set_signal, get_time],
    load = |env: rustler::Env, _: rustler::Term| {
        let _ = rustler::resource!(AutomatonResource, env);
        true
    }
);