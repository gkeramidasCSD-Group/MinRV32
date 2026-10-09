-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   UNIT TESTBENCH PATTERN  A small, focused TB that validates one RTL block
--       (alu) in isolation.
--
--   GOLDEN MODEL FUNCTION  alu_model() is a pure function that computes the
--       expected result in "software" so we can compare against the DUT.
--
--   PROCEDURE-BASED CHECKS  check() bundles stimulus + expected computation +
--       assertions into one call, making test vectors easy to read.
--
--   ASSERTIONS + SEVERITY  assert ... severity error marks a failing test; the
--       simulator exits with non-zero status when errors occur.
--
--   SIMULATION CONTROL  std.env.finish ends the simulation immediately after
--       printing a PASS message.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library std;
use std.env.all;
use work.core_pkg.all;

entity tb_alu is
end entity tb_alu;

architecture sim of tb_alu is
  signal op     : ALUControl_t := ALU_ADD;
  signal a      : word_t := (others => '0');
  signal b      : word_t := (others => '0');
  signal result : word_t;

  function alu_model(op_in : ALUControl_t; a_in : word_t; b_in : word_t) return word_t is
    variable res   : word_t := (others => '0');
    variable shamt : natural := 0;
  begin
    shamt := to_integer(unsigned(b_in(4 downto 0)));
    case op_in is
      when ALU_ADD  => res := std_logic_vector(signed(a_in) + signed(b_in));
      when ALU_SUB  => res := std_logic_vector(signed(a_in) - signed(b_in));
      when ALU_AND  => res := a_in and b_in;
      when ALU_OR   => res := a_in or b_in;
      when ALU_XOR  => res := a_in xor b_in;
      when ALU_SLT  =>
        if signed(a_in) < signed(b_in) then
          res(0) := '1';
        end if;
      when ALU_SLTU =>
        if unsigned(a_in) < unsigned(b_in) then
          res(0) := '1';
        end if;
      when ALU_SLL  => res := std_logic_vector(shift_left(unsigned(a_in), shamt));
      when ALU_SRL  => res := std_logic_vector(shift_right(unsigned(a_in), shamt));
      when ALU_SRA  => res := std_logic_vector(shift_right(signed(a_in), shamt));
    end case;
    return res;
  end function;

  procedure check(
    signal op_s : out ALUControl_t;
    signal a_s  : out word_t;
    signal b_s  : out word_t;
    signal res_s: in  word_t;
    op_in       : ALUControl_t;
    a_in        : word_t;
    b_in        : word_t;
    label_in    : string
  ) is
    variable expected : word_t;
  begin
    -- Drive the DUT inputs
    op_s <= op_in;
    a_s <= a_in;
    b_s <= b_in;
    -- Wait for the DUT to process the inputs and produce a stable output
    -- For zero-delay combinatorial RTL, any positive time is enough
    -- For sequential RTL, this should be at least one clock cycle after the inputs change
    wait for 1 ns;
    -- Compute the expected result using the golden model function
    expected := alu_model(op_in, a_in, b_in);
    -- Assert that the DUT output matches the expected result
    assert res_s = expected
      report "ALU mismatch (" & label_in & ")"
      severity error;
  end procedure;
begin
  dut : entity work.alu
    port map (
      op     => op,
      a      => a,
      b      => b,
      result => result
    );

  stim : process
  begin
    check(op, a, b, result, ALU_ADD,  x"00000000", x"00000000", "add zero");
    check(op, a, b, result, ALU_ADD,  x"00000001", x"00000002", "add small");
    check(op, a, b, result, ALU_SUB,  x"00000003", x"00000001", "sub small");
    check(op, a, b, result, ALU_AND,  x"0f0f0f0f", x"00ff00ff", "and");
    check(op, a, b, result, ALU_OR,   x"0f0f0f0f", x"00ff00ff", "or");
    check(op, a, b, result, ALU_XOR,  x"0f0f0f0f", x"00ff00ff", "xor");
    check(op, a, b, result, ALU_SLT,  x"ffffffff", x"00000001", "slt -1 < 1");
    check(op, a, b, result, ALU_SLTU, x"00000001", x"ffffffff", "sltu 1 < 0xffffffff");

    check(op, a, b, result, ALU_SLL,  x"00000001", x"0000001f", "sll 31");
    check(op, a, b, result, ALU_SRL,  x"80000000", x"0000001f", "srl 31");
    check(op, a, b, result, ALU_SRA,  x"80000000", x"0000001f", "sra 31");

    report "tb_alu: PASS" severity note;
    finish;
  end process;
end architecture sim;
