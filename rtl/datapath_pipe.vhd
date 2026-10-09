-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   STRUCTURAL ARCHITECTURE  After refactoring, this architecture contains no
--       logic of its own. It instantiates five pipeline-stage wrappers
--       (fetch, decode, execute, memory, writeback) and wires their ports
--       together. Each stage, in turn, instantiates pipe_reg entities so
--       every pipeline boundary is a named, clickable block in Vivado's
--       elaborated design schematic.
--
--   PORT MAP  Entity instantiation with `port map` connects hierarchical
--       sub-modules into the datapath. Each `=>` associates a formal port
--       (left) with an actual signal or expression (right).
--
--   BRAM-AS-PIPELINE-REGISTER  The instruction and data BRAMs use synchronous
--       reads, so their output registers *are* the F->D and M->W pipeline
--       registers for imem_instr_id and dmem_rdata_wb respectively.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: datapath_pipe
-- Structural datapath that sequences the five pipeline stage wrappers
-- (fetch, decode, execute, memory, writeback) and wires their inter-stage
-- signals. Each stage in turn instantiates pipe_reg entities, making every
-- pipeline boundary a named block in Vivado's elaborated design schematic.
-- ============================================================================
entity datapath_pipe is
  port (
    clk       : in  std_logic;
    rst       : in  std_logic;
    -- Fetch stage control.
    StallF    : in  std_logic;
    -- Decode stage control.
    StallD    : in  std_logic;
    FlushD    : in  std_logic;
    ImmSrcD   : in  ImmSrc_t;
    -- Execute stage control.
    FlushE    : in  std_logic;
    ForwardAE : in  std_logic_vector(1 downto 0);
    ForwardBE : in  std_logic_vector(1 downto 0);
    PCSrcE    : in  std_logic;
    JalrE     : in  std_logic;
    ALUControlE : in ALUControl_t;
    SrcASelE  : in  SrcASel_t;
    ALUSrcBE  : in  std_logic;
    BranchOpE : in  BranchOp_t;
    -- Memory stage control.
    MemWriteM   : in  std_logic;
    MemReadM    : in  std_logic;
    MemSizeM    : in  std_logic_vector(1 downto 0);
    -- Writeback stage control.
    RegWriteW : in  std_logic;
    ResultSrcW: in  ResultSrc_t;
    MemSizeW  : in  std_logic_vector(1 downto 0);
    MemUnsignedW : in std_logic;
    -- Instruction memory interface (BRAM-style registered output).
    imem_addr : out word_t;
    imem_rdata: in  word_t;
    imem_en   : out std_logic;
    -- Data memory interface (BRAM-style registered output).
    dmem_addr     : out word_t;
    dmem_wdata    : out word_t;
    dmem_rdata    : in  word_t;
    dmem_wstrb    : out std_logic_vector(3 downto 0);
    dmem_write_en : out std_logic;
    dmem_read_en  : out std_logic;
    -- Decode outputs for controller/hazard unit.
    opD      : out std_logic_vector(6 downto 0);
    funct3D  : out std_logic_vector(2 downto 0);
    funct7b5D: out std_logic;
    ZeroE    : out std_logic;
    -- Hazard unit taps.
    Rs1D : out std_logic_vector(4 downto 0);
    Rs2D : out std_logic_vector(4 downto 0);
    Rs1E : out std_logic_vector(4 downto 0);
    Rs2E : out std_logic_vector(4 downto 0);
    RdE  : out std_logic_vector(4 downto 0);
    RdM  : out std_logic_vector(4 downto 0);
    RdW  : out std_logic_vector(4 downto 0)
  );
end entity datapath_pipe;

architecture structural of datapath_pipe is
  -- Inter-stage wiring signals.
  signal pc_f_i            : word_t;
  signal pc_plus4_f_i      : word_t;

  signal rs1_data_d_i      : word_t;
  signal rs2_data_d_i      : word_t;
  signal imm_d_i           : word_t;
  signal rd_d_i            : std_logic_vector(4 downto 0);
  signal pc_d_i            : word_t;
  signal pc_plus4_d_i      : word_t;

  signal alu_result_e_i    : word_t;
  signal write_data_e_i    : word_t;
  signal pc_plus4_e_i      : word_t;
  signal branch_target_e_i : word_t;
  signal jalr_target_e_i   : word_t;
  signal rd_e_i            : std_logic_vector(4 downto 0);

  signal rd_m_i            : std_logic_vector(4 downto 0);
  signal alu_result_m_i    : word_t;
  signal pc_plus4_m_i      : word_t;

  signal rd_w_i            : std_logic_vector(4 downto 0);
  signal wb_result_w_i     : word_t;
begin

  -- ==========================================================================
  -- FETCH STAGE
  -- ==========================================================================
  fetch_inst : entity work.fetch_stage
    port map (
      clk             => clk,
      rst             => rst,
      StallF          => StallF,
      StallD          => StallD,
      PCSrcE          => PCSrcE,
      JalrE           => JalrE,
      branch_target_e => branch_target_e_i,
      jalr_target_e   => jalr_target_e_i,
      pc_f            => pc_f_i,
      pc_plus4_f      => pc_plus4_f_i,
      imem_en         => imem_en
    );

  imem_addr <= pc_f_i;

  -- ==========================================================================
  -- DECODE STAGE
  -- ==========================================================================
  decode_inst : entity work.decode_stage
    port map (
      clk         => clk,
      rst         => rst,
      StallD      => StallD,
      FlushD      => FlushD,
      ImmSrcD     => ImmSrcD,
      pc_f        => pc_f_i,
      pc_plus4_f  => pc_plus4_f_i,
      imem_rdata  => imem_rdata,
      RegWriteW   => RegWriteW,
      rd_w        => rd_w_i,
      wb_result_w => wb_result_w_i,
      op_d        => opD,
      funct3_d    => funct3D,
      funct7b5_d  => funct7b5D,
      rs1_d       => Rs1D,
      rs2_d       => Rs2D,
      rs1_data_d  => rs1_data_d_i,
      rs2_data_d  => rs2_data_d_i,
      imm_d       => imm_d_i,
      rd_d        => rd_d_i,
      pc_d        => pc_d_i,
      pc_plus4_d  => pc_plus4_d_i
    );

  -- ==========================================================================
  -- EXECUTE STAGE
  -- ==========================================================================
  execute_inst : entity work.execute_stage
    port map (
      clk             => clk,
      rst             => rst,
      FlushE          => FlushE,
      ForwardAE       => ForwardAE,
      ForwardBE       => ForwardBE,
      ALUControlE     => ALUControlE,
      SrcASelE        => SrcASelE,
      ALUSrcBE        => ALUSrcBE,
      BranchOpE       => BranchOpE,
      rs1_data_d      => rs1_data_d_i,
      rs2_data_d      => rs2_data_d_i,
      pc_d            => pc_d_i,
      imm_d           => imm_d_i,
      pc_plus4_d      => pc_plus4_d_i,
      rd_d            => rd_d_i,
      rs1_addr_d      => Rs1D,
      rs2_addr_d      => Rs2D,
      alu_result_m    => alu_result_m_i,
      wb_result_w     => wb_result_w_i,
      rs1_e           => Rs1E,
      rs2_e           => Rs2E,
      rd_e            => rd_e_i,
      zero_e          => ZeroE,
      alu_result_e    => alu_result_e_i,
      write_data_e    => write_data_e_i,
      pc_plus4_e      => pc_plus4_e_i,
      branch_target_e => branch_target_e_i,
      jalr_target_e   => jalr_target_e_i
    );

  RdE <= rd_e_i;

  -- ==========================================================================
  -- MEMORY STAGE
  -- ==========================================================================
  memory_inst : entity work.memory_stage
    port map (
      clk           => clk,
      rst           => rst,
      MemWriteM     => MemWriteM,
      MemReadM      => MemReadM,
      MemSizeM      => MemSizeM,
      alu_result_e  => alu_result_e_i,
      write_data_e  => write_data_e_i,
      rd_e          => rd_e_i,
      pc_plus4_e    => pc_plus4_e_i,
      rd_m          => rd_m_i,
      alu_result_m  => alu_result_m_i,
      pc_plus4_m    => pc_plus4_m_i,
      dmem_addr     => dmem_addr,
      dmem_wdata    => dmem_wdata,
      dmem_wstrb    => dmem_wstrb,
      dmem_write_en => dmem_write_en,
      dmem_read_en  => dmem_read_en
    );

  RdM <= rd_m_i;

  -- ==========================================================================
  -- WRITEBACK STAGE
  -- ==========================================================================
  writeback_inst : entity work.writeback_stage
    port map (
      clk          => clk,
      rst          => rst,
      ResultSrcW   => ResultSrcW,
      MemSizeW     => MemSizeW,
      MemUnsignedW => MemUnsignedW,
      alu_result_m => alu_result_m_i,
      rd_m         => rd_m_i,
      pc_plus4_m   => pc_plus4_m_i,
      dmem_rdata   => dmem_rdata,
      rd_w         => rd_w_i,
      wb_result_w  => wb_result_w_i
    );

  RdW <= rd_w_i;

end architecture structural;
