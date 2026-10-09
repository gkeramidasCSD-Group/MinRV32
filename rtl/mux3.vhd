-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   WITH/SELECT (Selected Signal Assignment)  An alternative to when/else that
--       maps each possible value of a select expression to an output. This is
--       analogous to a case statement but written as a *concurrent* assignment
--       (outside a process). Synthesis produces a multiplexer.
--
--   ASSERT (simulation guard)  Assertions fire during simulation when a
--       condition is violated. The "synthesis translate_off / on" comments tell
--       the synthesis tools to ignore the assert -- it exists only for debugging.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

-- ============================================================================
-- Entity: mux3
-- Generic 3:1 mux with a 2-bit select (00/01/10).
-- ============================================================================
entity mux3 is
  generic (
    WIDTH : natural := 32
  );
  port (
    d0 : in  std_logic_vector(WIDTH - 1 downto 0);
    d1 : in  std_logic_vector(WIDTH - 1 downto 0);
    d2 : in  std_logic_vector(WIDTH - 1 downto 0);
    s  : in  std_logic_vector(1 downto 0);
    y  : out std_logic_vector(WIDTH - 1 downto 0)
  );
end entity mux3;

architecture rtl of mux3 is
begin
  -- synthesis translate_off
  assert s /= "11"
    report "mux3: illegal select value 11"
    severity warning;
  -- synthesis translate_on

  with s select
    y <= d0 when "00",
         d1 when "01",
         d2 when "10",
         (others => '0') when others;
end architecture rtl;
