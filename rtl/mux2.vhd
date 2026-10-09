-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   ENTITY / ARCHITECTURE  The two fundamental building blocks. The entity
--       declares the module's interface (ports and generics); the architecture
--       describes the implementation. Think of entity as the black-box
--       (input/output) view of the module, and the architecture as the
--       internal description.
--
--   GENERIC        A compile-time parameter that makes the module reusable.
--       WIDTH defaults to 32 but can be overridden in each instantiation
--       (see generic map in datapath_pipe.vhd). Generics have no hardware
--       cost -- synthesis resolves them to constants before mapping.
--
--   CONCURRENT ASSIGNMENT (when/else)  Outside a process, signal assignments
--       execute *continuously* in parallel, modelling combinational logic.
--       The "when/else" conditional form maps to a multiplexer.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;

-- ============================================================================
-- Entity: mux2
-- Textbook-style 2:1 mux used to build SrcA/SrcB selection.
-- ============================================================================
entity mux2 is
  generic (
    WIDTH : natural := 32  -- Parametric width; overridden via generic map.
  );
  port (
    d0 : in  std_logic_vector(WIDTH - 1 downto 0);  -- Input when s = '0'.
    d1 : in  std_logic_vector(WIDTH - 1 downto 0);  -- Input when s = '1'.
    s  : in  std_logic;                              -- Select line.
    y  : out std_logic_vector(WIDTH - 1 downto 0)    -- Mux output.
  );
end entity mux2;

architecture rtl of mux2 is
begin
  -- Concurrent conditional assignment -- synthesizes to a 2:1 mux.
  y <= d1 when s = '1' else d0;
end architecture rtl;
