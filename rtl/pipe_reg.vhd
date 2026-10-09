-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   GENERIC PIPELINE REGISTER  A reusable building block parameterized by
--       WIDTH. Every pipeline boundary in the datapath instantiates one or
--       more copies. Each instance appears as a named block in Vivado's
--       elaborated design, making the pipeline structure immediately visible.
--
--   PRIORITY-ENCODED CONTROL  The process implements the standard pipeline-
--       register priority: reset/flush (highest) > stall > normal load.
--       This is the canonical pattern for pipelined CPU registers.
-- ============================================================================

-- ============================================================================
-- Entity: pipe_reg
-- Generic pipeline register with synchronous reset, flush, and stall control.
-- Each instantiation appears as a named, drillable block in Vivado's
-- elaborated design schematic, making pipeline boundaries easy to navigate.
--
--   rst / flush : clear the register to all zeros on the rising edge.
--   stall       : hold the current value (suppress the load).
--   Normal      : latch d into q.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

entity pipe_reg is
  generic (
    WIDTH : natural := 32
  );
  port (
    clk   : in  std_logic;
    rst   : in  std_logic;
    flush : in  std_logic;
    stall : in  std_logic;
    d     : in  std_logic_vector(WIDTH - 1 downto 0);
    q     : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity pipe_reg;

architecture rtl of pipe_reg is
begin
  p_pipe_reg : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or flush = '1' then
        q <= (others => '0');
      elsif stall = '0' then
        q <= d;
      end if;
    end if;
  end process p_pipe_reg;
end architecture rtl;
