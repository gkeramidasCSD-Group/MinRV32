-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   SIGNED / UNSIGNED comparisons  The same 32-bit vector can represent
--       either a signed or unsigned integer. BLT/BGE use `signed(rs1_data)`,
--       while BLTU/BGEU use `unsigned(rs1_data)`. VHDL requires the explicit
--       cast so the '<' operator knows which comparison semantics to apply.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: branch_unit
-- Combinational comparator dedicated to branch decisions. Evaluates RS1/RS2
-- in parallel with ALU work so the branch outcome is available within the
-- execute stage.
-- Supported BranchOp_t modes (RV32I): BR_NONE, BR_EQ/NE, BR_LT/GE, BR_LTU/GEU.
-- ============================================================================

entity branch_unit is
  port (
    op       : in  BranchOp_t;
    rs1_data : in  word_t;
    rs2_data : in  word_t;
    taken    : out std_logic
  );
end entity branch_unit;

architecture rtl of branch_unit is
begin
  -- Purpose: Execute-stage branch comparator (combinational). Evaluates the
  -- selected relational test and outputs the branch-taken flag.
  p_branch_compare : process(op, rs1_data, rs2_data)
    variable cond : std_logic := '0';
  begin
    case op is
      when BR_NONE =>
        -- No branch requested; always fall through.
        cond := '0';
      when BR_EQ =>
        -- BEQ triggers when RS1 equals RS2.
        if rs1_data = rs2_data then
          cond := '1';
        else
          cond := '0';
        end if;
      when BR_NE =>
        -- BNE triggers when RS1 differs from RS2.
        if rs1_data /= rs2_data then
          cond := '1';
        else
          cond := '0';
        end if;
      when BR_LT =>
        -- BLT uses signed comparison.
        if signed(rs1_data) < signed(rs2_data) then
          cond := '1';
        else
          cond := '0';
        end if;
      when BR_GE =>
        -- BGE uses signed comparison.
        if signed(rs1_data) >= signed(rs2_data) then
          cond := '1';
        else
          cond := '0';
        end if;
      when BR_LTU =>
        -- BLTU uses unsigned magnitude compare.
        if unsigned(rs1_data) < unsigned(rs2_data) then
          cond := '1';
        else
          cond := '0';
        end if;
      when BR_GEU =>
        -- BGEU uses unsigned comparison.
        if unsigned(rs1_data) >= unsigned(rs2_data) then
          cond := '1';
        else
          cond := '0';
        end if;
    end case;
    taken <= cond;
  end process p_branch_compare;
end architecture rtl;
