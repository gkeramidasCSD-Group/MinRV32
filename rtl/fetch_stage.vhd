-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   STRUCTURAL SUB-HIERARCHY  This stage wrapper groups the PC register, PC+4
--       adder, and next-PC muxes into one entity. Synthesis sees a flat netlist,
--       but in Vivado's elaborated design each wrapper appears as a named,
--       drillable block -- making pipeline boundaries easy to navigate.
--
--   CONCURRENT ARITHMETIC  The PC+4 adder is a concurrent signal assignment
--       using ieee.numeric_std unsigned addition. No process is needed because
--       the addition is purely combinational.
-- ============================================================================

-- ============================================================================
-- Entity: fetch_stage
-- Fetch pipeline stage wrapper. Contains the program counter register,
-- PC+4 adder, next-PC selection muxes (branch/JALR redirect), and the BRAM
-- read-enable logic. Each sub-component is a named instantiation visible in
-- Vivado's elaborated design.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

entity fetch_stage is
  port (
    clk             : in  std_logic;
    rst             : in  std_logic;
    -- Pipeline control.
    StallF          : in  std_logic;
    StallD          : in  std_logic;
    -- Branch/jump redirect from execute stage.
    PCSrcE          : in  std_logic;
    JalrE           : in  std_logic;
    branch_target_e : in  word_t;
    jalr_target_e   : in  word_t;
    -- Outputs.
    pc_f            : out word_t;
    pc_plus4_f      : out word_t;
    imem_en         : out std_logic
  );
end entity fetch_stage;

architecture rtl of fetch_stage is
  signal pc_i          : word_t;
  signal pc_next_i     : word_t;
  signal pc_plus4_i    : word_t;
  signal pc_redirect_i : word_t;
begin

  -- PC + 4 adder.
  pc_plus4_i <= std_logic_vector(unsigned(pc_i) + to_unsigned(4, XLEN));

  -- Select branch or JALR target.
  pc_branch_or_jalr_mux : entity work.mux2
    generic map (WIDTH => XLEN)
    port map (
      d0 => branch_target_e,
      d1 => jalr_target_e,
      s  => JalrE,
      y  => pc_redirect_i
    );

  -- Select PC+4 (sequential) or redirect (taken branch/jump).
  pc_next_mux : entity work.mux2
    generic map (WIDTH => XLEN)
    port map (
      d0 => pc_plus4_i,
      d1 => pc_redirect_i,
      s  => PCSrcE,
      y  => pc_next_i
    );

  -- Program counter register.
  pc_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (
      clk   => clk,
      rst   => rst,
      flush => '0',
      stall => StallF,
      d     => pc_next_i,
      q     => pc_i
    );

  -- Drive outputs.
  pc_f       <= pc_i;
  pc_plus4_f <= pc_plus4_i;

  -- BRAM read-enable: deasserting keeps the BRAM output register stable
  -- during decode stalls, matching the original pipeline register hold.
  imem_en <= '1' when rst = '0' and StallD = '0' else '0';

end architecture rtl;
