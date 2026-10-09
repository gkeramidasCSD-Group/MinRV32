-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   GENERATE STATEMENT  `if ... generate` creates or omits blocks of hardware
--       based on a compile-time boolean generic. The FORWARDING_ENABLE
--       generic lets the same code produce either a forwarding-capable or
--       a stall-only hazard unit -- without any run-time cost.
--
--   BOOLEAN EXPRESSIONS for control  VHDL booleans (true/false) differ from
--       std_logic ('0'/'1'). The hazard unit uses boolean conditions inside
--       if-generate but std_logic signals for outputs -- a common pattern
--       when mixing structural-level decisions with port-level data.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

-- ============================================================================
-- Entity: hazard_unit
-- Classic 5-stage hazard unit with forwarding, load-use stall, and flush.
-- Mirrors the Harris & Harris pipeline control flow.
-- ============================================================================

entity hazard_unit is
  generic (
    FORWARDING_ENABLE : boolean := true
  );
  port (
    Rs1D         : in  std_logic_vector(4 downto 0);
    Rs2D         : in  std_logic_vector(4 downto 0);
    Rs1E         : in  std_logic_vector(4 downto 0);
    Rs2E         : in  std_logic_vector(4 downto 0);
    RdE          : in  std_logic_vector(4 downto 0);
    RdM          : in  std_logic_vector(4 downto 0);
    RdW          : in  std_logic_vector(4 downto 0);
    PCSrcE       : in  std_logic;
    ResultSrcEb0 : in  std_logic;
    RegWriteE    : in  std_logic;
    RegWriteM    : in  std_logic;
    MemReadM     : in  std_logic;
    RegWriteW    : in  std_logic;
    ForwardAE    : out std_logic_vector(1 downto 0);
    ForwardBE    : out std_logic_vector(1 downto 0);
    StallF       : out std_logic;
    StallD       : out std_logic;
    FlushD       : out std_logic;
    FlushE       : out std_logic
  );
end entity hazard_unit;

architecture rtl of hazard_unit is
  function is_zero(reg : std_logic_vector(4 downto 0)) return boolean is
  begin
    return reg = "00000";
  end function;
  signal stallD_i : std_logic;
begin

  -- ==========================================================================
  -- FORWARDING ENABLED
  -- ==========================================================================
  -- With forwarding paths from M and W back to the E-stage ALU inputs,
  -- most RAW (Read-After-Write) data hazards are resolved without stalling.
  -- The only remaining data hazard is the load-use case: a load produces
  -- its result at the end of the M stage, which is too late to forward
  -- into the same cycle's E stage, so a one-cycle stall is required.
  -- ==========================================================================
  gen_fwd : if FORWARDING_ENABLE generate
    signal lwStallD_b : boolean;
  begin

    -- ---- Data-forwarding mux control ------------------------------------
    -- ForwardAE / ForwardBE select which value feeds each ALU operand:
    --   "00" --> register-file output (no hazard, or source is x0)
    --   "10" --> ALUResultM           (forward from M stage)
    --   "01" --> ResultW              (forward from W stage)
    --
    -- Priority rule: M before W. When two in-flight instructions write
    -- the same register, the one in M is *newer* (entered the pipe later),
    -- so its result must take precedence.
    --
    -- Example of why priority matters:
    --   add x1, x2, x3   (now in W, has an old x1)
    --   sub x1, x4, x5   (now in M, has the newest x1)
    --   or  x6, x1, x7   (now in E, needs the newest x1 --> forward from M)
    -- Purpose: Forwarding mux selects (combinational). Generates ForwardAE/BE
    -- with M-stage priority over W-stage, and blocks unsafe forwarding from
    -- loads (MemReadM=1).
    p_forward_select : process(Rs1E, Rs2E, RdM, RdW, RegWriteM, RegWriteW, MemReadM)
    begin
      ForwardAE <= "00";
      ForwardBE <= "00";

      -- ----- ForwardAE (first ALU source, Rs1) ---------------------------
      if not is_zero(Rs1E) then
        -- x0 is hardwired to zero -- never a hazard source, skip it.

        -- M-stage forwarding:
        -- Only safe when the producer is an ALU-type instruction whose
        -- result (ALUResultM) is already computed and sitting on the bus.
        -- If the producer is a LOAD (MemReadM='1'), the data memory has
        -- not produced the value yet -- forwarding ALUResultM would capture
        -- the *address* (ALU output) instead of the loaded data, silently
        -- corrupting execution. Loads are handled by the load-use stall
        -- below; after the stall, the value reaches W and is forwarded
        -- from there.
        if (Rs1E = RdM) and RegWriteM = '1' and MemReadM = '0' then
          ForwardAE <= "10";

        -- W-stage forwarding:
        -- ResultW is always the final committed value -- whether it came
        -- from the ALU, the data memory (load), or PC+4 (JAL/JALR).
        -- Therefore forwarding from W is always safe regardless of the
        -- original instruction type.
        elsif (Rs1E = RdW) and RegWriteW = '1' then
          ForwardAE <= "01";
        end if;
      end if;

      -- ----- ForwardBE (second ALU source, Rs2) -- same rules -------------
      if not is_zero(Rs2E) then
        if (Rs2E = RdM) and RegWriteM = '1' and MemReadM = '0' then
          ForwardBE <= "10";
        elsif (Rs2E = RdW) and RegWriteW = '1' then
          ForwardBE <= "01";
        end if;
      end if;
    end process p_forward_select;

    -- ---- Load-use stall -------------------------------------------------
    -- Issue: a load in E (ResultSrcEb0='1') will only produce its result
    -- at the end of M. If the very next instruction (now in D) reads that
    -- same register, the result is not yet available to forward.
    --
    -- Solution: stall F and D for one cycle, and flush E to insert a
    -- bubble (NOP). After the extra cycle the load has moved to W, where
    -- its value (ResultW) can be forwarded normally to E.
    --
    -- The is_zero guard avoids false stalls: x0 is always zero and is
    -- never a real dependency.
    lwStallD_b <= (ResultSrcEb0 = '1') and
                  ((Rs1D = RdE and not is_zero(Rs1D)) or
                   (Rs2D = RdE and not is_zero(Rs2D)));

    stallD_i <= '1' when lwStallD_b else '0';
  end generate gen_fwd;

  -- ==========================================================================
  -- FORWARDING DISABLED
  -- ==========================================================================
  -- Without bypass paths the ALU always reads from the register file.
  -- Every RAW hazard must therefore be resolved by stalling: the Decode
  -- stage is frozen until the producing instruction has written its result
  -- back in the W stage. This is simpler but significantly reduces IPC,
  -- since even back-to-back ALU instructions cause multi-cycle stalls.
  -- ==========================================================================
  gen_no_fwd : if not FORWARDING_ENABLE generate
    signal lwStallD_b  : boolean;
    signal rawStallD_b : boolean;
  begin
    -- No forwarding paths -- muxes permanently select the register-file
    -- output ("00").
    ForwardAE <= "00";
    ForwardBE <= "00";

    -- ---- Load-use stall -------------------------------------------------
    -- Same check as in the forwarding-enabled case: a load in E will only
    -- have its data ready in W. If D reads that register, one stall cycle
    -- is needed. (In no-forwarding mode this is technically a subset of
    -- the RAW stall below, but keeping it explicit mirrors the textbook
    -- decomposition and makes the intent clear.)
    lwStallD_b <= (ResultSrcEb0 = '1') and
                  ((Rs1D = RdE and not is_zero(Rs1D)) or
                   (Rs2D = RdE and not is_zero(Rs2D)));

    -- ---- General RAW stall ----------------------------------------------
    -- Issue: without forwarding, if the instruction in D reads a source
    -- register (Rs1D or Rs2D) that matches the destination of ANY in-flight
    -- instruction (E, M, or W) that has not yet written back, the register
    -- file still holds the old value.
    --
    -- Solution: stall F and D (and flush E) until the producer reaches W
    -- and commits the new value.
    --
    -- Critical guards that prevent *false* stalls:
    --
    --   * RegWriteE/M/W = '1':
    --     Some instruction encodings place a non-zero value in the Rd field
    --     even though they do NOT actually write a register -- stores
    --     (S-type) and branches (B-type) reuse those bits for the immediate.
    --     Without checking the RegWrite control signal, those would appear
    --     to be producers, causing unnecessary stalls on non-existent
    --     dependencies.
    --
    --   * not is_zero(RdE/M/W):
    --     Register x0 is hardwired to zero in RISC-V. No instruction can
    --     change it, so a "write to x0" is effectively discarded. We must
    --     exclude it to avoid stalling on instructions that specify x0 as
    --     their destination (e.g., BEQ which encodes Rd=0).
    rawStallD_b <=
      ((Rs1D = RdE or Rs2D = RdE) and RegWriteE = '1' and not is_zero(RdE)) or
      ((Rs1D = RdM or Rs2D = RdM) and RegWriteM = '1' and not is_zero(RdM)) or
      ((Rs1D = RdW or Rs2D = RdW) and RegWriteW = '1' and not is_zero(RdW));

    stallD_i <= '1' when (lwStallD_b or rawStallD_b) else '0';
  end generate gen_no_fwd;

  -- ==========================================================================
  -- Common stall / flush outputs (identical for both modes)
  -- ==========================================================================

  -- StallF / StallD: freeze the PC and the F/D pipeline register so the
  -- same instruction remains in D until the data hazard clears.
  --
  -- Interaction with taken branches:
  -- Issue: if a taken branch (PCSrcE='1') coincides with a data stall,
  -- blindly asserting Stall would freeze F/D on the *wrong-path*
  -- instruction. The branch wants to redirect F to the target, but the
  -- stall prevents F from updating -- the pipe would loop forever on the
  -- stale instruction.
  -- Solution: the "and not PCSrcE" term releases the stall whenever a
  -- branch redirects the PC, allowing F to fetch the correct target.
  StallF <= stallD_i and not PCSrcE;
  StallD <= stallD_i and not PCSrcE;

  -- FlushD: when a branch/jump resolves as taken in E, the instruction
  -- currently sitting in D was fetched speculatively from the fall-through
  -- path. It must be killed (replaced with a bubble / NOP) so it does not
  -- execute and corrupt architectural state.
  -- When PCSrcE='1', FlushD is already '1', which means the F/D register
  -- will be cleared regardless of StallD. The 'and not PCSrcE' on StallD is
  -- therefore not strictly required for correctness -- flush wins over stall,
  -- so even if StallD were asserted simultaneously with FlushD, the register
  -- would still be flushed to a bubble.
  FlushD <= PCSrcE;

  -- FlushE: insert a bubble into E in two independent situations:
  --   1. Data stall -- D is frozen so the instruction already in E must not
  --      be executed a second time; a NOP replaces it.
  --   2. Taken branch -- the instruction that entered E from the wrong
  --      path must be squashed to prevent incorrect side effects.
  FlushE <= stallD_i or PCSrcE;

end architecture rtl;
