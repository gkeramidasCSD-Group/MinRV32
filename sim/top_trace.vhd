-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   SIMULATION-ONLY WRAPPER  top_trace adds debug/trace ports without touching
--       the synthesizable top-level (rtl/top.vhd). This keeps FPGA builds
--       clean while still enabling rich waveform inspection in simulation.
--
--   STRUCTURAL INTEGRATION  This architecture is mostly wiring: it instantiates
--       the traced core wrapper (riscvpipe_trace) plus IMEM/DMEM models and
--       connects their ports.
--
--   GENERICS for reuse  Memory depths and init files are generics, letting one
--       wrapper support multiple programs/configurations.
--
--   GUARDING META-VALUES  addr_valid() is checked before converting addresses
--       with numeric_std. This avoids issues when X/U/Z appear during reset or
--       when signals are intentionally left uninitialized in early bring-up.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: top_trace
-- Simulation-only top wrapper that exposes basic signals for tracing while
-- keeping rtl/top.vhd synthesizable and unchanged.
-- ============================================================================

entity top_trace is
  generic (
    IMEM_WORDS     : natural := 2048;
    DMEM_WORDS     : natural := 2048;
    IMEM_INIT_FILE : string  := "";
    DMEM_INIT_FILE : string  := "";
    DMEM_BASE_ADDR : std_logic_vector(31 downto 0) := x"20000000";
    FORWARDING_ENABLE : boolean := true
  );
  port (
    clk            : in  std_logic;
    reset          : in  std_logic;
    WriteData      : out std_logic_vector(31 downto 0);
    DataAdr        : out std_logic_vector(31 downto 0);
    MemWrite       : out std_logic;
    MemRead        : out std_logic;
    MemWStrb       : out std_logic_vector(3 downto 0);
    PCDbg          : out std_logic_vector(31 downto 0);
    InstrDbg       : out std_logic_vector(31 downto 0);
    result_src_dbg : out ResultSrc_t;
    mem_write_dbg  : out std_logic;
    mem_read_dbg   : out std_logic;
    pc_src_dbg     : out std_logic;
    alu_src_dbg    : out std_logic;
    reg_write_dbg  : out std_logic;
    jump_dbg       : out std_logic;
    jalr_dbg       : out std_logic;
    imm_src_dbg    : out ImmSrc_t;
    alu_control_dbg: out ALUControl_t;
    mem_size_dbg   : out std_logic_vector(1 downto 0);
    mem_unsigned_dbg: out std_logic;
    branch_op_dbg  : out BranchOp_t;
    src_a_sel_dbg  : out SrcASel_t;
    branch_taken_dbg: out std_logic;
    -- Hazard/forwarding visibility (useful for teaching/debug).
    stall_f_dbg     : out std_logic;
    stall_d_dbg     : out std_logic;
    flush_d_dbg     : out std_logic;
    flush_e_dbg     : out std_logic;
    forward_a_dbg   : out std_logic_vector(1 downto 0);
    forward_b_dbg   : out std_logic_vector(1 downto 0);
    -- Per-stage instruction word tracking (trace annotation).
    instr_d_dbg     : out std_logic_vector(31 downto 0);
    instr_e_dbg     : out std_logic_vector(31 downto 0);
    instr_m_dbg     : out std_logic_vector(31 downto 0);
    instr_w_dbg     : out std_logic_vector(31 downto 0)
  );
end entity top_trace;

architecture structural of top_trace is
  signal pc         : word_t;
  signal instr      : word_t;
  signal read_data  : word_t;
  signal imem_data  : word_t;
  signal dmem_rdata : word_t;

  -- Internal memory interface nets. These are driven by the core and then
  -- exposed on the top-level ports for observation.
  signal dmem_addr_i     : word_t;
  signal dmem_wdata_i    : word_t;
  signal dmem_wstrb_i    : std_logic_vector(3 downto 0);
  signal dmem_write_en_i : std_logic;
  signal dmem_read_en_i  : std_logic;

  signal imem_en    : std_logic;
  signal use_imem_w : std_logic := '0';
begin

  -- Expose core memory interface signals on the textbook-style top ports.
  WriteData <= dmem_wdata_i;
  DataAdr   <= dmem_addr_i;
  MemWrite  <= dmem_write_en_i;
  MemRead   <= dmem_read_en_i;
  MemWStrb  <= dmem_wstrb_i;

  rvpipe_inst : entity work.riscvpipe_trace
    generic map (
      FORWARDING_ENABLE => FORWARDING_ENABLE
    )
    port map (
      clk           => clk,
      rst           => reset,
      imem_addr     => pc,
      imem_rdata    => instr,
      imem_en       => imem_en,
      dmem_addr     => dmem_addr_i,
      dmem_wdata    => dmem_wdata_i,
      dmem_rdata    => read_data,
      dmem_wstrb    => dmem_wstrb_i,
      dmem_write_en => dmem_write_en_i,
      dmem_read_en  => dmem_read_en_i,
      result_src_dbg   => result_src_dbg,
      mem_write_dbg    => mem_write_dbg,
      mem_read_dbg     => mem_read_dbg,
      pc_src_dbg       => pc_src_dbg,
      alu_src_dbg      => alu_src_dbg,
      reg_write_dbg    => reg_write_dbg,
      jump_dbg         => jump_dbg,
      jalr_dbg         => jalr_dbg,
      imm_src_dbg      => imm_src_dbg,
      alu_control_dbg  => alu_control_dbg,
      mem_size_dbg     => mem_size_dbg,
      mem_unsigned_dbg => mem_unsigned_dbg,
      branch_op_dbg    => branch_op_dbg,
      src_a_sel_dbg    => src_a_sel_dbg,
      branch_taken_dbg => branch_taken_dbg,
      stall_f_dbg      => stall_f_dbg,
      stall_d_dbg      => stall_d_dbg,
      flush_d_dbg      => flush_d_dbg,
      flush_e_dbg      => flush_e_dbg,
      forward_a_dbg    => forward_a_dbg,
      forward_b_dbg    => forward_b_dbg,
      instr_d_dbg      => instr_d_dbg,
      instr_e_dbg      => instr_e_dbg,
      instr_m_dbg      => instr_m_dbg,
      instr_w_dbg      => instr_w_dbg
    );

  PCDbg   <= pc;
  InstrDbg <= instr;

  imem_dp_inst : entity work.imem_dp
    generic map (
      WORDS    => IMEM_WORDS,
      INIT_HEX => IMEM_INIT_FILE
    )
    port map (
      clk     => clk,
      en_a    => imem_en,
      addr_a  => pc,
      rdata_a => instr,
      en_b    => dmem_read_en_i,
      addr_b  => dmem_addr_i,
      rdata_b => imem_data
    );

  dmem_inst : entity work.dmem
    generic map (
      WORDS    => DMEM_WORDS,
      INIT_HEX => DMEM_INIT_FILE
    )
    port map (
      clk   => clk,
      addr  => dmem_addr_i,
      wdata => dmem_wdata_i,
      rdata => dmem_rdata,
      wstrb => dmem_wstrb_i,
      write => dmem_write_en_i,
      read  => dmem_read_en_i
    );

  -- Purpose: Register the IMEM-vs-DMEM read select so it aligns with the
  -- synchronous BRAM outputs that also latch on this clock edge.
  p_use_imem_w_reg : process(clk)
  begin
    if rising_edge(clk) then
      if reset = '1' then
        use_imem_w <= '0';
      elsif addr_valid(dmem_addr_i) then
        if unsigned(dmem_addr_i) < unsigned(DMEM_BASE_ADDR) then
          use_imem_w <= '1';
        else
          use_imem_w <= '0';
        end if;
      else
        use_imem_w <= '0';
      end if;
    end if;
  end process p_use_imem_w_reg;

  read_data <= imem_data when use_imem_w = '1' else dmem_rdata;

end architecture structural;
