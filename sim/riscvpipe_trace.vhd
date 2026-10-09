-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   STRUCTURAL ARCHITECTURE  The traced core wrapper contains no new CPU logic;
--       it instantiates the real controller/datapath/hazard units and simply
--       exposes selected internal control/status signals as extra output ports.
--
--   DIRECT ENTITY INSTANTIATION  Uses `entity work.<name> port map (...)`
--       bindings instead of component declarations, keeping the wrapper small
--       and easy to follow.
--
--   TRACE PORTS  Signals like ResultSrc/MemRead/PCSrc and forwarding/stall/flush
--       outputs are made visible to the testbench so it can print a textual
--       pipeline trace or drive waveform labels.
--
--   GENERICS (compile-time feature switch)  FORWARDING_ENABLE controls which
--       hazard-unit generate path is active in the RTL while the wrapper stays
--       identical.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: riscvpipe_trace
-- Pipelined core wrapper that exposes control/status signals for tracing.
-- ============================================================================

entity riscvpipe_trace is
  generic (
    FORWARDING_ENABLE : boolean := true
  );
  port (
    clk            : in  std_logic;
    rst            : in  std_logic;
    -- Instruction memory interface.
    imem_addr      : out word_t;
    imem_rdata     : in  word_t;
    imem_en        : out std_logic;
    -- Data memory interface.
    dmem_addr      : out word_t;
    dmem_wdata     : out word_t;
    dmem_rdata     : in  word_t;
    dmem_wstrb     : out std_logic_vector(3 downto 0);
    dmem_write_en  : out std_logic;
    dmem_read_en   : out std_logic;
    -- Trace outputs (pipeline-aware).
    result_src_dbg  : out ResultSrc_t;
    mem_write_dbg   : out std_logic;
    mem_read_dbg    : out std_logic;
    pc_src_dbg      : out std_logic;
    alu_src_dbg     : out std_logic;
    reg_write_dbg   : out std_logic;
    jump_dbg        : out std_logic;
    jalr_dbg        : out std_logic;
    imm_src_dbg     : out ImmSrc_t;
    alu_control_dbg : out ALUControl_t;
    mem_size_dbg    : out std_logic_vector(1 downto 0);
    mem_unsigned_dbg: out std_logic;
    branch_op_dbg   : out BranchOp_t;
    src_a_sel_dbg   : out SrcASel_t;
    branch_taken_dbg: out std_logic;
    -- Hazard/forwarding visibility (useful for teaching/debug).
    stall_f_dbg     : out std_logic;
    stall_d_dbg     : out std_logic;
    flush_d_dbg     : out std_logic;
    flush_e_dbg     : out std_logic;
    forward_a_dbg   : out std_logic_vector(1 downto 0);
    forward_b_dbg   : out std_logic_vector(1 downto 0);
    -- Per-stage instruction word tracking (trace annotation).
    instr_d_dbg     : out word_t;
    instr_e_dbg     : out word_t;
    instr_m_dbg     : out word_t;
    instr_w_dbg     : out word_t
  );
end entity riscvpipe_trace;

architecture structural of riscvpipe_trace is
  signal StallF       : std_logic;
  signal StallD       : std_logic;
  signal FlushD       : std_logic;
  signal FlushE       : std_logic;
  signal ForwardAE    : std_logic_vector(1 downto 0);
  signal ForwardBE    : std_logic_vector(1 downto 0);

  -- Internal memory interface nets. These decouple sub-module wiring from the
  -- entity ports and make it easy to insert instrumentation or adapters later.
  signal imem_addr_i     : word_t;
  signal imem_en_i       : std_logic;
  signal dmem_addr_i     : word_t;
  signal dmem_wdata_i    : word_t;
  signal dmem_wstrb_i    : std_logic_vector(3 downto 0);
  signal dmem_write_en_i : std_logic;
  signal dmem_read_en_i  : std_logic;

  signal opD          : std_logic_vector(6 downto 0);
  signal funct3D      : std_logic_vector(2 downto 0);
  signal funct7b5D    : std_logic;
  signal ImmSrcD      : ImmSrc_t;
  signal ALUControlE  : ALUControl_t;
  signal SrcASelE     : SrcASel_t;
  signal ALUSrcBE     : std_logic;
  signal BranchOpE    : BranchOp_t;
  signal JalrE        : std_logic;
  signal JumpE        : std_logic;
  signal PCSrcE       : std_logic;
  signal ZeroE        : std_logic;
  signal ResultSrcEb0 : std_logic;
  signal RegWriteE    : std_logic;
  signal RegWriteM    : std_logic;
  signal RegWriteW    : std_logic;
  signal ResultSrcW   : ResultSrc_t;
  signal MemWriteM    : std_logic;
  signal MemReadM     : std_logic;
  signal MemSizeM     : std_logic_vector(1 downto 0);
  signal MemUnsignedM : std_logic;
  signal MemSizeW     : std_logic_vector(1 downto 0);
  signal MemUnsignedW : std_logic;

  signal Rs1D : std_logic_vector(4 downto 0);
  signal Rs2D : std_logic_vector(4 downto 0);
  signal Rs1E : std_logic_vector(4 downto 0);
  signal Rs2E : std_logic_vector(4 downto 0);
  signal RdE  : std_logic_vector(4 downto 0);
  signal RdM  : std_logic_vector(4 downto 0);
  signal RdW  : std_logic_vector(4 downto 0);

  -- Trace-only: instruction word tracking through pipeline stages.
  -- Replicates the flush_d_hold NOP mux from decode_stage so InstrD_t
  -- matches the actual instruction used by the controller, then pipes
  -- the word through E/M/W using the same flush/stall controls as the
  -- real pipeline registers.
  constant NOP_INSTR_T : word_t := x"00000013";
  signal flush_d_hold_t : std_logic := '1';
  signal InstrD_t       : word_t;
  signal InstrE_t       : word_t;
  signal InstrM_t       : word_t;
  signal InstrW_t       : word_t;
begin

  -- Expose internal nets on the core's memory interface ports.
  imem_addr     <= imem_addr_i;
  imem_en       <= imem_en_i;
  dmem_addr     <= dmem_addr_i;
  dmem_wdata    <= dmem_wdata_i;
  dmem_wstrb    <= dmem_wstrb_i;
  dmem_write_en <= dmem_write_en_i;
  dmem_read_en  <= dmem_read_en_i;

  ctrl_inst : entity work.controller_pipe
    port map (
      clk          => clk,
      rst          => rst,
      opD          => opD,
      funct3D      => funct3D,
      funct7b5D    => funct7b5D,
      StallD       => StallD,
      ZeroE        => ZeroE,
      FlushE       => FlushE,
      ImmSrcD      => ImmSrcD,
      ALUControlE  => ALUControlE,
      SrcASelE     => SrcASelE,
      ALUSrcBE     => ALUSrcBE,
      BranchOpE    => BranchOpE,
      JalrE        => JalrE,
      JumpE        => JumpE,
      PCSrcE       => PCSrcE,
      ResultSrcEb0 => ResultSrcEb0,
      RegWriteE    => RegWriteE,
      MemWriteM    => MemWriteM,
      MemReadM     => MemReadM,
      MemSizeM     => MemSizeM,
      MemUnsignedM => MemUnsignedM,
      RegWriteM    => RegWriteM,
      RegWriteW    => RegWriteW,
      ResultSrcW   => ResultSrcW,
      MemSizeW     => MemSizeW,
      MemUnsignedW => MemUnsignedW
    );

  datapath_inst : entity work.datapath_pipe
    port map (
      clk          => clk,
      rst          => rst,
      StallF       => StallF,
      StallD       => StallD,
      FlushD       => FlushD,
      ImmSrcD      => ImmSrcD,
      FlushE       => FlushE,
      ForwardAE    => ForwardAE,
      ForwardBE    => ForwardBE,
      PCSrcE       => PCSrcE,
      JalrE        => JalrE,
      ALUControlE  => ALUControlE,
      SrcASelE     => SrcASelE,
      ALUSrcBE     => ALUSrcBE,
      BranchOpE    => BranchOpE,
      MemWriteM    => MemWriteM,
      MemReadM     => MemReadM,
      MemSizeM     => MemSizeM,
      RegWriteW    => RegWriteW,
      ResultSrcW   => ResultSrcW,
      MemSizeW     => MemSizeW,
      MemUnsignedW => MemUnsignedW,
      imem_addr    => imem_addr_i,
      imem_rdata   => imem_rdata,
      imem_en      => imem_en_i,
      dmem_addr    => dmem_addr_i,
      dmem_wdata   => dmem_wdata_i,
      dmem_rdata   => dmem_rdata,
      dmem_wstrb   => dmem_wstrb_i,
      dmem_write_en => dmem_write_en_i,
      dmem_read_en  => dmem_read_en_i,
      opD          => opD,
      funct3D      => funct3D,
      funct7b5D    => funct7b5D,
      ZeroE        => ZeroE,
      Rs1D         => Rs1D,
      Rs2D         => Rs2D,
      Rs1E         => Rs1E,
      Rs2E         => Rs2E,
      RdE          => RdE,
      RdM          => RdM,
      RdW          => RdW
    );

  hazard_inst : entity work.hazard_unit
    generic map (
      FORWARDING_ENABLE => FORWARDING_ENABLE
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

  result_src_dbg   <= ResultSrcW;
  mem_write_dbg    <= MemWriteM;
  mem_read_dbg     <= MemReadM;
  pc_src_dbg       <= PCSrcE;
  alu_src_dbg      <= ALUSrcBE;
  reg_write_dbg    <= RegWriteW;
  jump_dbg         <= JumpE;
  jalr_dbg         <= JalrE;
  imm_src_dbg      <= ImmSrcD;
  alu_control_dbg  <= ALUControlE;
  mem_size_dbg     <= MemSizeM;
  mem_unsigned_dbg <= MemUnsignedM;
  branch_op_dbg    <= BranchOpE;
  src_a_sel_dbg    <= SrcASelE;
  branch_taken_dbg <= ZeroE;

  stall_f_dbg   <= StallF;
  stall_d_dbg   <= StallD;
  flush_d_dbg   <= FlushD;
  flush_e_dbg   <= FlushE;
  forward_a_dbg <= ForwardAE;
  forward_b_dbg <= ForwardBE;

  -- ===========================================================================
  -- Trace-only instruction tracking pipeline.
  -- Mirrors the flush_d_hold logic from decode_stage and pipes the instruction
  -- word through E/M/W using pipe_reg instances with the same controls.
  -- ===========================================================================

  -- Replicate flush_d_hold register (mirrors decode_stage.vhd).
  p_flush_d_hold_trace : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        flush_d_hold_t <= '1';
      elsif StallD = '0' then
        flush_d_hold_t <= FlushD;
      end if;
    end if;
  end process p_flush_d_hold_trace;

  InstrD_t <= NOP_INSTR_T when flush_d_hold_t = '1' else imem_rdata;

  -- D->E instruction tracking register (flush on FlushE, no stall).
  de_instr_trace_reg : entity work.pipe_reg
    generic map (WIDTH => 32)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => InstrD_t, q => InstrE_t);

  -- E->M instruction tracking register (no flush, no stall).
  em_instr_trace_reg : entity work.pipe_reg
    generic map (WIDTH => 32)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => InstrE_t, q => InstrM_t);

  -- M->W instruction tracking register (no flush, no stall).
  mw_instr_trace_reg : entity work.pipe_reg
    generic map (WIDTH => 32)
    port map (clk => clk, rst => rst, flush => '0', stall => '0',
              d => InstrM_t, q => InstrW_t);

  instr_d_dbg <= InstrD_t;
  instr_e_dbg <= InstrE_t;
  instr_m_dbg <= InstrM_t;
  instr_w_dbg <= InstrW_t;
end architecture structural;
