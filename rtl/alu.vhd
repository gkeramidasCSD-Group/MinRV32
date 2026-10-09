-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   PROCESS (combinational)  A process with a *complete* sensitivity list
--       (all input signals listed) and no rising_edge() describes purely
--       combinational logic. The process body executes sequentially (like
--       software) but synthesis generates gates, not a state machine.
--
--   CASE statement  Inside a process, `case` maps an expression to mutually
--       exclusive branches. All enum values must be covered (or use
--       "when others") so the compiler verifies exhaustiveness.
--
--   VARIABLE  Declared with `:=` inside a process/function, variables update
--       *immediately* when assigned and can be read back in the same
--       sequential context. Contrast with SIGNAL which only updates after
--       the current simulation delta. Variables model temporary wires or
--       intermediate combinational nodes.
--
--   TYPE CONVERSIONS  VHDL is strict: std_logic_vector <-> signed/unsigned
--       must be explicit. `signed(a)` reinterprets bit patterns while
--       `std_logic_vector(signed_val)` converts back. The shift functions
--       in ieee.numeric_std operate on signed/unsigned, not plain slv.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: alu
-- Combinational RV32I ALU that implements arithmetic/logic ops plus shifts.
-- The control unit selects the `ALUControl_t`, and this block returns the matching
-- 32-bit result without any internal state.
-- Supported operations (see `ALUControl_t`):
--   ALU_ADD  / ALU_SUB  - signed add/sub
--   ALU_AND  / ALU_OR   / ALU_XOR - bitwise logical ops
--   ALU_SLT  / ALU_SLTU - signed/unsigned < comparisons (result[0]=1 on true)
--   ALU_SLL  / ALU_SRL  / ALU_SRA - logical/arithmetic shifts (B[4:0] amount)
-- ============================================================================

entity alu is
  port (
    op     : in  ALUControl_t;
    a      : in  word_t;
    b      : in  word_t;
    result : out word_t
  );
end entity alu;

architecture rtl of alu is
begin
  -- Purpose: Execute-stage ALU (combinational). Computes the result for the
  -- selected ALUControl_t operation.
  p_alu_comb : process(op, a, b)
    variable alu_res : word_t;
  begin
    alu_res := (others => '0');
    case op is
      when ALU_ADD =>
        -- Signed addition handles ADD/ADDI/AUIPC path.
        alu_res := std_logic_vector(signed(a) + signed(b));
      when ALU_SUB =>
        -- Signed subtraction handles SUB instruction.
        alu_res := std_logic_vector(signed(a) - signed(b));
      when ALU_AND =>
        -- Bitwise logical operations rely on std_logic_vector operators.
        alu_res := a and b;
      when ALU_OR =>
        alu_res := a or b;
      when ALU_XOR =>
        alu_res := a xor b;
      when ALU_SLT =>
        -- Signed comparison returns bit0=1 when RS1 < RS2.
        if signed(a) < signed(b) then
          alu_res(0) := '1';
        end if;
      when ALU_SLTU =>
        -- Unsigned compare variant for SLTU.
        if unsigned(a) < unsigned(b) then
          alu_res(0) := '1';
        end if;
      when ALU_SLL =>
        -- Logical left shift; shift amount from B[4:0].
        alu_res := std_logic_vector(shift_left(unsigned(a),
                     to_integer(unsigned(b(4 downto 0)))));
      when ALU_SRL =>
        -- Logical right shift with zero-fill.
        alu_res := std_logic_vector(shift_right(unsigned(a),
                     to_integer(unsigned(b(4 downto 0)))));
      when ALU_SRA =>
        -- Arithmetic right shift preserves sign bit.
        alu_res := std_logic_vector(shift_right(signed(a),
                     to_integer(unsigned(b(4 downto 0)))));
    end case;
    result <= alu_res;
  end process p_alu_comb;
end architecture rtl;
