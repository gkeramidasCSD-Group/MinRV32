-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   STRUCTURAL ARCHITECTURE  This architecture contains *no* logic of its own.
--       It only instantiates sub-entities and wires their ports together with
--       internal signals. This style maps directly to a schematic: each
--       `entity work.<name> port map (...)` is a placed component.
--
--   ENTITY INSTANTIATION (direct binding)  VHDL-93 introduced
--       `entity work.<name>` for directly naming the entity to instantiate
--       (avoid separate component declarations). The `port map` clause
--       connects each formal port to an actual signal or expression.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: riscvpipe
-- Pipelined core wrapper that binds controller, datapath, and hazard unit.
-- ============================================================================

entity riscvpipe is
  generic (
    FORWARDING_ENABLE : boolean := true
  );
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- Instruction memory interface.
    imem_addr     : out word_t;
    imem_rdata    : in  word_t;
    imem_en       : out std_logic;
    -- Data memory interface.
    dmem_addr     : out word_t;
    dmem_wdata    : out word_t;
    dmem_rdata    : in  word_t;
    dmem_wstrb    : out std_logic_vector(3 downto 0);
    dmem_write_en : out std_logic;
    dmem_read_en  : out std_logic
  );
end entity riscvpipe;

architecture structural of riscvpipe is
  signal haz_stall_if      : std_logic;
  signal haz_stall_id      : std_logic;
  signal haz_flush_id      : std_logic;
  signal haz_flush_ex      : std_logic;
  signal haz_forward_a_ex  : std_logic_vector(1 downto 0);
  signal haz_forward_b_ex  : std_logic_vector(1 downto 0);

  -- Internal memory interface nets. These decouple sub-module wiring from the
  -- entity ports and make it easy to insert instrumentation or adapters later.
  signal dp_imem_addr_if      : word_t;
  signal dp_imem_en_if        : std_logic;
  signal dp_dmem_addr_mem     : word_t;
  signal dp_dmem_wdata_mem    : word_t;
  signal dp_dmem_wstrb_mem    : std_logic_vector(3 downto 0);
  signal dp_dmem_write_en_mem : std_logic;
  signal dp_dmem_read_en_mem  : std_logic;

  -- Instruction decode fields (decoded from the instruction word in D stage).
  signal op_d       : std_logic_vector(6 downto 0);
  signal funct3_d   : std_logic_vector(2 downto 0);
  signal funct7b5_d : std_logic;
  signal ctrl_imm_src_id      : ImmSrc_t;
  signal ctrl_alu_control_ex  : ALUControl_t;
  signal ctrl_src_a_sel_ex    : SrcASel_t;
  signal ctrl_alu_src_b_ex    : std_logic;
  signal ctrl_branch_op_ex    : BranchOp_t;
  signal ctrl_jalr_ex         : std_logic;
  signal ctrl_jump_ex         : std_logic;
  signal ctrl_pcsrc_ex        : std_logic;
  signal branch_taken_ex      : std_logic;
  signal ctrl_result_src_is_mem_ex : std_logic;
  signal ctrl_reg_write_ex    : std_logic;
  signal ctrl_reg_write_mem   : std_logic;
  signal ctrl_reg_write_wb    : std_logic;
  signal ctrl_result_src_wb   : ResultSrc_t;
  signal ctrl_mem_write_mem   : std_logic;
  signal ctrl_mem_read_mem    : std_logic;
  signal ctrl_mem_size_mem    : std_logic_vector(1 downto 0);
  signal ctrl_mem_size_wb     : std_logic_vector(1 downto 0);
  signal ctrl_mem_unsigned_wb : std_logic;

  -- Register addresses flowing through the pipeline (stage-suffixed).
  signal rs1_d  : std_logic_vector(4 downto 0);
  signal rs2_d  : std_logic_vector(4 downto 0);
  signal rs1_e  : std_logic_vector(4 downto 0);
  signal rs2_e  : std_logic_vector(4 downto 0);
  signal rd_e   : std_logic_vector(4 downto 0);
  signal rd_m   : std_logic_vector(4 downto 0);
  signal rd_w   : std_logic_vector(4 downto 0);
begin

  -- Expose internal nets on the core's memory interface ports.
  imem_addr     <= dp_imem_addr_if;
  imem_en       <= dp_imem_en_if;
  dmem_addr     <= dp_dmem_addr_mem;
  dmem_wdata    <= dp_dmem_wdata_mem;
  dmem_wstrb    <= dp_dmem_wstrb_mem;
  dmem_write_en <= dp_dmem_write_en_mem;
  dmem_read_en  <= dp_dmem_read_en_mem;

  ctrl_inst : entity work.controller_pipe
    port map (
      clk          => clk,
      rst          => rst,
      opD          => op_d,
      funct3D      => funct3_d,
      funct7b5D    => funct7b5_d,
      StallD       => haz_stall_id,
      ZeroE        => branch_taken_ex,
      FlushE       => haz_flush_ex,
      ImmSrcD      => ctrl_imm_src_id,
      ALUControlE  => ctrl_alu_control_ex,
      SrcASelE     => ctrl_src_a_sel_ex,
      ALUSrcBE     => ctrl_alu_src_b_ex,
      BranchOpE    => ctrl_branch_op_ex,
      JalrE        => ctrl_jalr_ex,
      JumpE        => ctrl_jump_ex,
      PCSrcE       => ctrl_pcsrc_ex,
      ResultSrcEb0 => ctrl_result_src_is_mem_ex,
      RegWriteE    => ctrl_reg_write_ex,
      MemWriteM    => ctrl_mem_write_mem,
      MemReadM     => ctrl_mem_read_mem,
      MemSizeM     => ctrl_mem_size_mem,
      MemUnsignedM => open,
      RegWriteM    => ctrl_reg_write_mem,
      RegWriteW    => ctrl_reg_write_wb,
      ResultSrcW   => ctrl_result_src_wb,
      MemSizeW     => ctrl_mem_size_wb,
      MemUnsignedW => ctrl_mem_unsigned_wb
    );

  datapath_inst : entity work.datapath_pipe
    port map (
      clk          => clk,
      rst          => rst,
      StallF       => haz_stall_if,
      StallD       => haz_stall_id,
      FlushD       => haz_flush_id,
      ImmSrcD      => ctrl_imm_src_id,
      FlushE       => haz_flush_ex,
      ForwardAE    => haz_forward_a_ex,
      ForwardBE    => haz_forward_b_ex,
      PCSrcE       => ctrl_pcsrc_ex,
      JalrE        => ctrl_jalr_ex,
      ALUControlE  => ctrl_alu_control_ex,
      SrcASelE     => ctrl_src_a_sel_ex,
      ALUSrcBE     => ctrl_alu_src_b_ex,
      BranchOpE    => ctrl_branch_op_ex,
      MemWriteM    => ctrl_mem_write_mem,
      MemReadM     => ctrl_mem_read_mem,
      MemSizeM     => ctrl_mem_size_mem,
      RegWriteW    => ctrl_reg_write_wb,
      ResultSrcW   => ctrl_result_src_wb,
      MemSizeW     => ctrl_mem_size_wb,
      MemUnsignedW => ctrl_mem_unsigned_wb,
      imem_addr    => dp_imem_addr_if,
      imem_rdata   => imem_rdata,
      imem_en      => dp_imem_en_if,
      dmem_addr    => dp_dmem_addr_mem,
      dmem_wdata   => dp_dmem_wdata_mem,
      dmem_rdata   => dmem_rdata,
      dmem_wstrb   => dp_dmem_wstrb_mem,
      dmem_write_en => dp_dmem_write_en_mem,
      dmem_read_en  => dp_dmem_read_en_mem,
      opD          => op_d,
      funct3D      => funct3_d,
      funct7b5D    => funct7b5_d,
      ZeroE        => branch_taken_ex,
      Rs1D         => rs1_d,
      Rs2D         => rs2_d,
      Rs1E         => rs1_e,
      Rs2E         => rs2_e,
      RdE          => rd_e,
      RdM          => rd_m,
      RdW          => rd_w
    );

  hazard_inst : entity work.hazard_unit
    generic map (
      FORWARDING_ENABLE => FORWARDING_ENABLE
    )
    port map (
      Rs1D         => rs1_d,
      Rs2D         => rs2_d,
      Rs1E         => rs1_e,
      Rs2E         => rs2_e,
      RdE          => rd_e,
      RdM          => rd_m,
      RdW          => rd_w,
      PCSrcE       => ctrl_pcsrc_ex,
      ResultSrcEb0 => ctrl_result_src_is_mem_ex,
      RegWriteE    => ctrl_reg_write_ex,
      RegWriteM    => ctrl_reg_write_mem,
      MemReadM     => ctrl_mem_read_mem,
      RegWriteW    => ctrl_reg_write_wb,
      ForwardAE    => haz_forward_a_ex,
      ForwardBE    => haz_forward_b_ex,
      StallF       => haz_stall_if,
      StallD       => haz_stall_id,
      FlushD       => haz_flush_id,
      FlushE       => haz_flush_ex
    );
end architecture structural;
