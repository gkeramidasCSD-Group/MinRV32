-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   TESTING GENERATE BRANCHES  hazard_unit has two implementations selected by
--       a boolean generic (FORWARDING_ENABLE). This TB instantiates *both*
--       variants so regressions in either mode are caught.
--
--   EXPECTATION HELPERS  expect_forward() and expect_pipe() capture the
--       "assert-after-delay" pattern used in combinational checking.
--
--   HAZARD SEMANTICS  The vectors cover:
--     - M/W forwarding select encoding
--     - load-use stall (StallF/StallD + FlushE)
--     - control redirect interaction (PCSrcE releases stalls)
--     - RAW stalling behavior when forwarding is disabled
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
library std;
use std.env.all;

entity tb_hazard_unit is
end entity tb_hazard_unit;

architecture sim of tb_hazard_unit is
  signal Rs1D         : std_logic_vector(4 downto 0) := (others => '0');
  signal Rs2D         : std_logic_vector(4 downto 0) := (others => '0');
  signal Rs1E         : std_logic_vector(4 downto 0) := (others => '0');
  signal Rs2E         : std_logic_vector(4 downto 0) := (others => '0');
  signal RdE          : std_logic_vector(4 downto 0) := (others => '0');
  signal RdM          : std_logic_vector(4 downto 0) := (others => '0');
  signal RdW          : std_logic_vector(4 downto 0) := (others => '0');
  signal PCSrcE       : std_logic := '0';
  signal ResultSrcEb0 : std_logic := '0';
  signal RegWriteE    : std_logic := '0';
  signal RegWriteM    : std_logic := '0';
  signal MemReadM     : std_logic := '0';
  signal RegWriteW    : std_logic := '0';
  signal ForwardAE    : std_logic_vector(1 downto 0);
  signal ForwardBE    : std_logic_vector(1 downto 0);
  signal StallF       : std_logic;
  signal StallD       : std_logic;
  signal FlushD       : std_logic;
  signal FlushE       : std_logic;

  signal ForwardAE_nofwd : std_logic_vector(1 downto 0);
  signal ForwardBE_nofwd : std_logic_vector(1 downto 0);
  signal StallF_nofwd    : std_logic;
  signal StallD_nofwd    : std_logic;
  signal FlushD_nofwd    : std_logic;
  signal FlushE_nofwd    : std_logic;

  procedure expect_forward(
    signal actA : in std_logic_vector(1 downto 0);
    signal actB : in std_logic_vector(1 downto 0);
    expA : std_logic_vector(1 downto 0);
    expB : std_logic_vector(1 downto 0);
    label_in : string
  ) is
  begin
    wait for 1 ns;
    assert actA = expA report "ForwardAE mismatch (" & label_in & ")" severity error;
    assert actB = expB report "ForwardBE mismatch (" & label_in & ")" severity error;
  end procedure;

  procedure expect_pipe(
    signal actStallF : in std_logic;
    signal actStallD : in std_logic;
    signal actFlushD : in std_logic;
    signal actFlushE : in std_logic;
    expStallF : std_logic;
    expStallD : std_logic;
    expFlushD : std_logic;
    expFlushE : std_logic;
    label_in : string
  ) is
  begin
    wait for 1 ns;
    assert actStallF = expStallF report "StallF mismatch (" & label_in & ")" severity error;
    assert actStallD = expStallD report "StallD mismatch (" & label_in & ")" severity error;
    assert actFlushD = expFlushD report "FlushD mismatch (" & label_in & ")" severity error;
    assert actFlushE = expFlushE report "FlushE mismatch (" & label_in & ")" severity error;
  end procedure;
begin
  dut_fwd : entity work.hazard_unit
    generic map (
      FORWARDING_ENABLE => true
    )
    port map (
      Rs1D         => Rs1D,
      Rs2D         => Rs2D,
      Rs1E         => Rs1E,
      Rs2E         => Rs2E,
      RdE          => RdE,
      RdM          => RdM,
      RdW          => RdW,
      PCSrcE       => PCSrcE,
      ResultSrcEb0 => ResultSrcEb0,
      RegWriteE    => RegWriteE,
      RegWriteM    => RegWriteM,
      MemReadM     => MemReadM,
      RegWriteW    => RegWriteW,
      ForwardAE    => ForwardAE,
      ForwardBE    => ForwardBE,
      StallF       => StallF,
      StallD       => StallD,
      FlushD       => FlushD,
      FlushE       => FlushE
    );

  dut_no_fwd : entity work.hazard_unit
    generic map (
      FORWARDING_ENABLE => false
    )
    port map (
      Rs1D         => Rs1D,
      Rs2D         => Rs2D,
      Rs1E         => Rs1E,
      Rs2E         => Rs2E,
      RdE          => RdE,
      RdM          => RdM,
      RdW          => RdW,
      PCSrcE       => PCSrcE,
      ResultSrcEb0 => ResultSrcEb0,
      RegWriteE    => RegWriteE,
      RegWriteM    => RegWriteM,
      MemReadM     => MemReadM,
      RegWriteW    => RegWriteW,
      ForwardAE    => ForwardAE_nofwd,
      ForwardBE    => ForwardBE_nofwd,
      StallF       => StallF_nofwd,
      StallD       => StallD_nofwd,
      FlushD       => FlushD_nofwd,
      FlushE       => FlushE_nofwd
    );

  stim : process
  begin
    -- Forward from M stage (ALU producer): 10
    Rs1E <= "00001";
    RdM <= "00001";
    RegWriteM <= '1';
    MemReadM <= '0';
    expect_forward(ForwardAE, ForwardBE, "10", "00", "fwd: from M");
    expect_forward(ForwardAE_nofwd, ForwardBE_nofwd, "00", "00", "nofwd: no forwarding");

    -- If M stage is a load, do not forward ALUResultM.
    MemReadM <= '1';
    RdW <= "00001";
    RegWriteW <= '1';
    expect_forward(ForwardAE, ForwardBE, "01", "00", "fwd: from W when M is load");
    expect_forward(ForwardAE_nofwd, ForwardBE_nofwd, "00", "00", "nofwd: no forwarding on load");

    -- Priority: M overrides W when both match and are eligible.
    MemReadM <= '0';
    expect_forward(ForwardAE, ForwardBE, "10", "00", "fwd: M priority over W");
    expect_forward(ForwardAE_nofwd, ForwardBE_nofwd, "00", "00", "nofwd: no forwarding priority");

    -- Clear forwarding setup before stall-focused checks.
    Rs1E <= (others => '0');
    RdM <= (others => '0');
    RdW <= (others => '0');
    RegWriteM <= '0';
    RegWriteW <= '0';
    MemReadM <= '0';

    -- Load-use stall: ResultSrcEb0 means the E-stage instruction is a load.
    ResultSrcEb0 <= '1';
    RdE <= "00010";
    Rs1D <= "00010";
    PCSrcE <= '0';
    expect_pipe(StallF, StallD, FlushD, FlushE, '1', '1', '0', '1', "fwd: load-use stall");
    expect_pipe(StallF_nofwd, StallD_nofwd, FlushD_nofwd, FlushE_nofwd,
                '1', '1', '0', '1', "nofwd: load-use stall");

    -- Branch redirect releases stall of F/D but still flushes D/E.
    PCSrcE <= '1';
    expect_pipe(StallF, StallD, FlushD, FlushE, '0', '0', '1', '1', "fwd: branch redirect overrides stall");
    expect_pipe(StallF_nofwd, StallD_nofwd, FlushD_nofwd, FlushE_nofwd,
                '0', '0', '1', '1', "nofwd: branch redirect overrides stall");

    -- RAW hazard stalling (no-forwarding mode).
    PCSrcE <= '0';
    ResultSrcEb0 <= '0';
    Rs2D <= (others => '0');
    RegWriteM <= '0';
    RegWriteW <= '0';
    MemReadM <= '0';
    RegWriteE <= '1';
    RdE <= "00101";
    Rs1D <= "00101";
    expect_pipe(StallF_nofwd, StallD_nofwd, FlushD_nofwd, FlushE_nofwd, '1', '1', '0', '1', "nofwd: RAW stall vs RdE");
    expect_pipe(StallF, StallD, FlushD, FlushE, '0', '0', '0', '0', "fwd: no stall on ALU RAW hazard");
    expect_forward(ForwardAE_nofwd, ForwardBE_nofwd, "00", "00", "nofwd: forwards fixed at 00");

    -- x0 guard: writes to x0 must never create a dependency stall.
    RdE <= "00000";
    Rs1D <= "00000";
    expect_pipe(StallF_nofwd, StallD_nofwd, FlushD_nofwd, FlushE_nofwd, '0', '0', '0', '0', "nofwd: ignore x0");
    expect_pipe(StallF, StallD, FlushD, FlushE, '0', '0', '0', '0', "fwd: ignore x0");

    -- RAW stall from M stage (producer not yet committed).
    RegWriteE <= '0';
    RdE <= (others => '0');
    RegWriteM <= '1';
    RdM <= "00110";
    Rs1D <= (others => '0');
    Rs2D <= "00110";
    expect_pipe(StallF_nofwd, StallD_nofwd, FlushD_nofwd, FlushE_nofwd, '1', '1', '0', '1', "nofwd: RAW stall vs RdM");
    expect_pipe(StallF, StallD, FlushD, FlushE, '0', '0', '0', '0', "fwd: no stall vs RdM");

    -- RAW stall from W stage (still in-flight).
    RegWriteM <= '0';
    RdM <= (others => '0');
    RegWriteW <= '1';
    RdW <= "00111";
    Rs2D <= (others => '0');
    Rs1D <= "00111";
    expect_pipe(StallF_nofwd, StallD_nofwd, FlushD_nofwd, FlushE_nofwd, '1', '1', '0', '1', "nofwd: RAW stall vs RdW");
    expect_pipe(StallF, StallD, FlushD, FlushE, '0', '0', '0', '0', "fwd: no stall vs RdW");

    report "tb_hazard_unit: PASS" severity note;
    finish;
  end process;
end architecture sim;
