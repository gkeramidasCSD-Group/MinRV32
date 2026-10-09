-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   CLOCKED UNIT TEST  regfile has a synchronous write port, so this TB drives
--       a real clock and uses `wait until rising_edge(clk)` to align stimulus
--       with write commits.
--
--   CONCURRENT CLOCK GENERATION  `clk <= not clk after ...` builds a free-running
--       clock without an explicit process.
--
--   BYPASS / FORWARDING CHECK  The DUT implements a same-cycle write bypass;
--       the TB asserts that reads reflect rd_data immediately when addresses
--       match and rd_write='1'.
--
--   ASSERTIONS  Each requirement is checked with assert ... severity error so
--       failures stop the run and clearly identify the violated property.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
library std;
use std.env.all;
use work.core_pkg.all;

entity tb_regfile is
end entity tb_regfile;

architecture sim of tb_regfile is
  constant CLK_PERIOD : time := 10 ns;
  signal clk      : std_logic := '0';
  signal rs1_addr : std_logic_vector(4 downto 0) := (others => '0');
  signal rs2_addr : std_logic_vector(4 downto 0) := (others => '0');
  signal rd_addr  : std_logic_vector(4 downto 0) := (others => '0');
  signal rd_data  : word_t := (others => '0');
  signal rd_write : std_logic := '0';
  signal rs1_data : word_t;
  signal rs2_data : word_t;
begin
  dut : entity work.regfile
    port map (
      clk      => clk,
      rs1_addr => rs1_addr,
      rs2_addr => rs2_addr,
      rd_addr  => rd_addr,
      rd_data  => rd_data,
      rd_write => rd_write,
      rs1_data => rs1_data,
      rs2_data => rs2_data
    );

  clk <= not clk after CLK_PERIOD / 2;

  stim : process
  begin
    -- Power-on state should be zeroed.
    rs1_addr <= "00000";
    rs2_addr <= "00001";
    wait for 1 ns;
    assert rs1_data = x"00000000" report "x0 not zero at reset" severity error;
    assert rs2_data = x"00000000" report "x1 not zero at reset" severity error;

    -- Write x1 on rising edge with bypass.
    -- The combinational bypass mux makes the write data visible immediately
    -- when rd_write='1' and the read address matches the write address.
    rd_addr  <= "00001";
    rd_data  <= x"12345678";
    rd_write <= '1';
    rs2_addr <= "00001";
    wait for 1 ns;
    -- Bypass: rd_write='1', rs2_addr=rd_addr => rs2_data = rd_data immediately.
    assert rs2_data = x"12345678" report "bypass not forwarding write data" severity error;

    -- Commit the write on the next rising edge, then deassert rd_write.
    wait until rising_edge(clk);
    rd_write <= '0';
    wait for 1 ns;
    -- Value should now be in the register array (rising edge committed it).
    assert rs2_data = x"12345678" report "write not committed after rising edge" severity error;

    -- Writes to x0 are ignored.
    rd_addr  <= "00000";
    rd_data  <= x"ffffffff";
    rd_write <= '1';
    rs1_addr <= "00000";
    wait until rising_edge(clk);
    rd_write <= '0';
    wait for 1 ns;
    assert rs1_data = x"00000000" report "x0 changed by write" severity error;

    -- Invalid read addresses (X/U/Z) are treated as 0.
    rs1_addr <= "0000X";
    wait for 1 ns;
    assert rs1_data = x"00000000" report "invalid address did not read as 0" severity error;

    report "tb_regfile: PASS" severity note;
    finish;
  end process;
end architecture sim;
