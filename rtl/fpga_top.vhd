-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   FPGA WRAPPER  This is a thin wrapper whose only job is to hide the
--       textbook `top` entity's observation ports from the FPGA pad ring.
--       `top.vhd` exposes DataAdr/WriteData/MemWrite/MemRead/MemWStrb so the
--       VHDL testbench can observe memory traffic directly; that shape is
--       great for simulation but would consume ~70 FPGA I/O pins for signals
--       that are never physically wired on the board. `fpga_top` instantiates
--       `top` and collapses those ports into a single 1-bit `led` output.
--       Internal nets are still observable on hardware via ILA + MARK_DEBUG,
--       which does not need a top-level port.
--
--   DEAD-CODE ELIMINATION AVOIDANCE  Synthesis tools perform backwards
--       optimization from the design's outputs: any logic that cannot reach
--       an output pin is pruned. If every observation port were simply left
--       `open`, Vivado would remove the ALU, regfile, DMEM writes, and the
--       entire datapath because nothing outside the chip can "see" them.
--       To prevent that, every observation signal is XOR-reduced into an
--       `activity` net. Every bit of the observation interface therefore
--       reaches a real pin via the XOR tree, so synthesis must preserve the
--       full datapath.
--
--   CLOCK GENERATION  The board oscillator does not drive the core directly.
--       An MMCM (Mixed-Mode Clock Manager, the clock generator block inside
--       7-series FPGAs) turns the board clock into the core clock:
--
--           core clock = board clock * MMCM_MULT / (MMCM_DIVCLK * MMCM_OUT_DIV)
--
--       With the defaults (100 MHz board clock, 12, 1, 15) the core runs at
--       80 MHz. scripts/vivado_project.tcl computes these generics from the
--       core clock frequency you ask for, so you normally do not set them by
--       hand. Vivado derives the timing constraint of the core clock from the
--       MMCM settings and the board clock constraint in the XDC file, so
--       timing is always checked at the real core clock.
--
--   RESET SYNCHRONIZER  The core is held in reset while the reset button is
--       pressed and while the MMCM output is not yet stable (LOCKED = '0').
--       The reset is released through two flip-flops clocked by the core
--       clock, so it always ends on a clock edge.
--
--   VISIBLE BLINK DIVIDER  A purely combinational LED driver would toggle at
--       the core clock rate and the eye would see it as "always on". A free-
--       running counter ticks every clock cycle and the LED is driven from
--       its MSB, so the LED blinks at a few Hz whenever the clock is alive
--       -- a robust "board alive" indicator that does not depend on the
--       core actually issuing loads/stores.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ============================================================================
-- Entity: fpga_top
-- Synthesis-only top wrapper: exposes only `clk`, `reset`, and a single 1-bit
-- `led` so the FPGA pad ring stays small. It also generates the core clock
-- from the board clock with an MMCM. Simulation continues to use `top`
-- (and its trace wrapper `top_trace`) directly, keeping the testbench
-- observation interface intact.
-- ============================================================================

entity fpga_top is
  generic (
    IMEM_WORDS        : natural := 2048;
    DMEM_WORDS        : natural := 2048;
    IMEM_INIT_FILE    : string  := "";
    DMEM_INIT_FILE    : string  := "";
    FORWARDING_ENABLE : boolean := true;
    -- Board clock period in picoseconds (10000 = 100 MHz).
    CLK_IN_PERIOD_PS  : positive := 10000;
    -- MMCM settings. core clock = board clock * MMCM_MULT /
    -- (MMCM_DIVCLK * MMCM_OUT_DIV). Allowed ranges: MMCM_MULT 2..64,
    -- MMCM_DIVCLK 1..106, MMCM_OUT_DIV 1..128. The MMCM's internal oscillator
    -- (board clock * MMCM_MULT / MMCM_DIVCLK) must stay between 600 and
    -- 1200 MHz. vivado_project.tcl checks these limits.
    MMCM_MULT         : positive := 12;
    MMCM_DIVCLK       : positive := 1;
    MMCM_OUT_DIV      : positive := 15
  );
  port (
    clk   : in  std_logic;   -- board clock
    reset : in  std_logic;   -- active-high reset button
    -- 1-bit "board alive" indicator. Driven by the MSB of a free-running
    -- 24-bit counter (one blink every 2^24 core clock cycles: about 4.8 Hz
    -- at 80 MHz), XORed with the activity fold of every observation signal
    -- from `top` so synthesis cannot prune the datapath as dead code.
    led   : out std_logic
  );
end entity fpga_top;

architecture structural of fpga_top is
  -- Xilinx clocking primitives. They are declared here as components instead
  -- of through `library unisim`, so that GHDL and Yosys can still read this
  -- file: they treat the components as empty boxes. Vivado binds them to its
  -- own primitives. Only the ports and generics used here are declared.
  component MMCME2_BASE is
    generic (
      CLKIN1_PERIOD    : real;
      CLKFBOUT_MULT_F  : real;
      DIVCLK_DIVIDE    : integer;
      CLKOUT0_DIVIDE_F : real
    );
    port (
      CLKIN1   : in  std_logic;
      CLKFBIN  : in  std_logic;
      RST      : in  std_logic;
      PWRDWN   : in  std_logic;
      CLKOUT0  : out std_logic;
      CLKFBOUT : out std_logic;
      LOCKED   : out std_logic
    );
  end component;

  component BUFG is
    port (
      I : in  std_logic;
      O : out std_logic
    );
  end component;

  signal mmcm_out     : std_logic;   -- MMCM output, before the clock buffer
  signal mmcm_fb      : std_logic;   -- MMCM feedback, before the clock buffer
  signal mmcm_fb_buf  : std_logic;   -- MMCM feedback, after the clock buffer
  signal mmcm_locked  : std_logic;
  signal clk_core     : std_logic;   -- core clock
  signal reset_sync   : std_logic_vector(1 downto 0) := (others => '1');
  signal reset_core   : std_logic;
  -- Internal capture nets for the observation ports of `top`. Leaving these
  -- disconnected with `open` would re-introduce the dead-code problem.
  signal write_data_i : std_logic_vector(31 downto 0);
  signal data_adr_i   : std_logic_vector(31 downto 0);
  signal mem_write_i  : std_logic;
  signal mem_read_i   : std_logic;
  signal mem_wstrb_i  : std_logic_vector(3 downto 0);
  signal activity     : std_logic;
  signal blink_cnt    : unsigned(23 downto 0) := (others => '0');
begin

  -- Core clock generation. The feedback path goes through a global clock
  -- buffer, like the output, so the core clock is aligned with the board
  -- clock.
  mmcm_inst : MMCME2_BASE
    generic map (
      CLKIN1_PERIOD    => real(CLK_IN_PERIOD_PS) / 1000.0,
      CLKFBOUT_MULT_F  => real(MMCM_MULT),
      DIVCLK_DIVIDE    => MMCM_DIVCLK,
      CLKOUT0_DIVIDE_F => real(MMCM_OUT_DIV)
    )
    port map (
      CLKIN1   => clk,
      CLKFBIN  => mmcm_fb_buf,
      RST      => '0',
      PWRDWN   => '0',
      CLKOUT0  => mmcm_out,
      CLKFBOUT => mmcm_fb,
      LOCKED   => mmcm_locked
    );

  fb_bufg  : BUFG port map (I => mmcm_fb,  O => mmcm_fb_buf);
  clk_bufg : BUFG port map (I => mmcm_out, O => clk_core);

  -- Reset synchronizer: the reset starts at once (asynchronously) and ends
  -- two core clock edges after both the button is released and the MMCM
  -- is locked.
  process(clk_core, reset, mmcm_locked)
  begin
    if reset = '1' or mmcm_locked = '0' then
      reset_sync <= (others => '1');
    elsif rising_edge(clk_core) then
      reset_sync <= reset_sync(0) & '0';
    end if;
  end process;
  reset_core <= reset_sync(1);

  core_inst : entity work.top
    generic map (
      IMEM_WORDS        => IMEM_WORDS,
      DMEM_WORDS        => DMEM_WORDS,
      IMEM_INIT_FILE    => IMEM_INIT_FILE,
      DMEM_INIT_FILE    => DMEM_INIT_FILE,
      FORWARDING_ENABLE => FORWARDING_ENABLE
    )
    port map (
      clk       => clk_core,
      reset     => reset_core,
      WriteData => write_data_i,
      DataAdr   => data_adr_i,
      MemWrite  => mem_write_i,
      MemRead   => mem_read_i,
      MemWStrb  => mem_wstrb_i
    );

  -- XOR-reduce every observed bit into a single activity net. Uses VHDL-2008
  -- unary-reduction operators (`xor vec`). Every bit of the observation
  -- interface reaches a pad through this net, so synthesis must preserve the
  -- whole datapath.
  activity <= (xor write_data_i) xor (xor data_adr_i)
              xor mem_write_i xor mem_read_i xor (xor mem_wstrb_i);

  -- Free-running counter: increments every core clock cycle regardless of
  -- core activity. The MSB of a 24-bit counter completes one on/off cycle
  -- every 2^24 clock cycles (about 4.8 Hz at 80 MHz), so the LED blinks
  -- whenever the core clock is running -- a dependable "board alive"
  -- indicator that doesn't rely on the core actually executing loads/stores.
  process(clk_core)
  begin
    if rising_edge(clk_core) then
      blink_cnt <= blink_cnt + 1;
    end if;
  end process;

  -- LED = counter MSB XOR activity. The counter guarantees a visible blink;
  -- XORing `activity` in still forces every observation bit to reach the
  -- pad, so synthesis cannot prune the datapath as dead code.
  led <= blink_cnt(blink_cnt'high) xor activity;

end architecture structural;
