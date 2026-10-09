-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   PROCESS (synchronous / sequential)  A process containing
--       `if rising_edge(clk)` describes clocked (sequential) logic. Signals
--       assigned inside this block become D flip-flop outputs. This is how
--       pipeline control registers (D->E, E->M, M->W) are modelled.
--
--   MULTI-STAGE PIPELINE CONTROL  Each stage's control signals are captured
--       from the previous stage on the rising edge. Reset and flush clear
--       the registers to safe defaults, inserting "bubbles" into the pipe.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: controller_pipe
-- Pipelined control unit. Instantiates maindec and aludec in the Decode stage,
-- then pipelines all control signals through D->E, E->M, and M->W registers.
-- Reset and FlushE insert safe control bubbles; StallD holds the D->E register
-- to support load-use hazard stalls.
-- ============================================================================
entity controller_pipe is
  port (
    clk           : in  std_logic;
    rst           : in  std_logic;
    -- Decode stage inputs.
    opD           : in  std_logic_vector(6 downto 0);
    funct3D       : in  std_logic_vector(2 downto 0);
    funct7b5D     : in  std_logic;
    StallD        : in  std_logic;
    -- Execute stage feedback.
    ZeroE         : in  std_logic;
    FlushE        : in  std_logic;
    -- Decode stage outputs.
    ImmSrcD       : out ImmSrc_t;
    -- Execute stage outputs.
    ALUControlE   : out ALUControl_t;
    SrcASelE      : out SrcASel_t;
    ALUSrcBE      : out std_logic;
    BranchOpE     : out BranchOp_t;
    JalrE         : out std_logic;
    JumpE         : out std_logic;
    PCSrcE        : out std_logic;
    ResultSrcEb0  : out std_logic;
    RegWriteE     : out std_logic;
    -- Memory stage outputs.
    MemWriteM     : out std_logic;
    MemReadM      : out std_logic;
    MemSizeM      : out std_logic_vector(1 downto 0);
    MemUnsignedM  : out std_logic;
    RegWriteM     : out std_logic;
    -- Writeback stage outputs.
    RegWriteW     : out std_logic;
    ResultSrcW    : out ResultSrc_t;
    MemSizeW      : out std_logic_vector(1 downto 0);
    MemUnsignedW  : out std_logic
  );
end entity controller_pipe;

architecture rtl of controller_pipe is
  signal maindec_branch_id       : std_logic;
  signal maindec_alu_src_id      : std_logic;
  signal maindec_reg_write_id    : std_logic;
  signal maindec_jump_id         : std_logic;
  signal maindec_jalr_id         : std_logic;
  signal maindec_mem_write_id    : std_logic;
  signal maindec_mem_read_id     : std_logic;
  signal maindec_alu_op_id       : std_logic_vector(1 downto 0);
  signal maindec_src_a_sel_id    : SrcASel_t;
  signal maindec_result_src_id   : ResultSrc_t;
  signal maindec_mem_size_id     : std_logic_vector(1 downto 0);
  signal maindec_mem_unsigned_id : std_logic;
  signal maindec_branch_op_id    : BranchOp_t;
  signal aludec_alu_control_id   : ALUControl_t;

  signal maindec_reg_write_ex    : std_logic := '0';
  signal maindec_jump_ex         : std_logic := '0';
  signal maindec_jalr_ex         : std_logic := '0';
  signal maindec_branch_ex       : std_logic := '0';
  signal maindec_mem_write_ex    : std_logic := '0';
  signal maindec_mem_read_ex     : std_logic := '0';
  signal maindec_mem_size_ex     : std_logic_vector(1 downto 0) := MEM_WORD;
  signal maindec_mem_unsigned_ex : std_logic := '0';
  signal maindec_result_src_ex   : ResultSrc_t := WB_ALU;
  signal aludec_alu_control_ex   : ALUControl_t := ALU_ADD;
  signal maindec_src_a_sel_ex    : SrcASel_t := OPA_RS1;
  signal maindec_alu_src_ex      : std_logic := '0';
  signal maindec_branch_op_ex    : BranchOp_t := BR_NONE;

  signal maindec_result_src_mem   : ResultSrc_t := WB_ALU;
  signal maindec_reg_write_mem    : std_logic := '0';
  signal maindec_mem_write_mem    : std_logic := '0';
  signal maindec_mem_read_mem     : std_logic := '0';
  signal maindec_mem_size_mem     : std_logic_vector(1 downto 0) := MEM_WORD;
  signal maindec_mem_unsigned_mem : std_logic := '0';

  signal maindec_reg_write_wb    : std_logic := '0';
  signal maindec_result_src_wb   : ResultSrc_t := WB_ALU;
  signal maindec_mem_size_wb     : std_logic_vector(1 downto 0) := MEM_WORD;
  signal maindec_mem_unsigned_wb : std_logic := '0';
begin
  maindec_inst : entity work.maindec
    port map (
      op           => opD,
      funct3       => funct3D,
      result_src   => maindec_result_src_id,
      mem_write    => maindec_mem_write_id,
      mem_read     => maindec_mem_read_id,
      branch       => maindec_branch_id,
      alu_src      => maindec_alu_src_id,
      reg_write    => maindec_reg_write_id,
      jump         => maindec_jump_id,
      jalr         => maindec_jalr_id,
      imm_src      => ImmSrcD,
      alu_op       => maindec_alu_op_id,
      mem_size     => maindec_mem_size_id,
      mem_unsigned => maindec_mem_unsigned_id,
      branch_op    => maindec_branch_op_id,
      src_a_sel    => maindec_src_a_sel_id
    );

  aludec_inst : entity work.aludec
    port map (
      opb5        => opD(5),
      funct3      => funct3D,
      funct7b5    => funct7b5D,
      alu_op      => maindec_alu_op_id,
      alu_control => aludec_alu_control_id
    );

  -- Purpose: D->E control pipeline register. Reset/FlushE inserts a bubble, and
  -- StallD holds the previous control word.
  p_ctrl_d_to_e_reg : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' or FlushE = '1' then
        maindec_reg_write_ex    <= '0';
        maindec_result_src_ex   <= WB_ALU;
        maindec_mem_write_ex    <= '0';
        maindec_mem_read_ex     <= '0';
        maindec_jump_ex         <= '0';
        maindec_jalr_ex         <= '0';
        maindec_branch_ex       <= '0';
        aludec_alu_control_ex   <= ALU_ADD;
        maindec_src_a_sel_ex    <= OPA_RS1;
        maindec_alu_src_ex      <= '0';
        maindec_branch_op_ex    <= BR_NONE;
        maindec_mem_size_ex     <= MEM_WORD;
        maindec_mem_unsigned_ex <= '0';
      elsif StallD = '0' then
        maindec_reg_write_ex    <= maindec_reg_write_id;
        maindec_result_src_ex   <= maindec_result_src_id;
        maindec_mem_write_ex    <= maindec_mem_write_id;
        maindec_mem_read_ex     <= maindec_mem_read_id;
        maindec_jump_ex         <= maindec_jump_id;
        maindec_jalr_ex         <= maindec_jalr_id;
        maindec_branch_ex       <= maindec_branch_id;
        aludec_alu_control_ex   <= aludec_alu_control_id;
        maindec_src_a_sel_ex    <= maindec_src_a_sel_id;
        maindec_alu_src_ex      <= maindec_alu_src_id;
        maindec_branch_op_ex    <= maindec_branch_op_id;
        maindec_mem_size_ex     <= maindec_mem_size_id;
        maindec_mem_unsigned_ex <= maindec_mem_unsigned_id;
      end if;
    end if;
  end process p_ctrl_d_to_e_reg;

  PCSrcE       <= (maindec_branch_ex and ZeroE) or maindec_jump_ex;
  ResultSrcEb0 <= '1' when maindec_result_src_ex = WB_MEM else '0';

  -- Purpose: E->M control pipeline register. Captures memory-stage controls
  -- and the RegWriteM qualifier.
  p_ctrl_e_to_m_reg : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        maindec_reg_write_mem    <= '0';
        maindec_result_src_mem   <= WB_ALU;
        maindec_mem_write_mem    <= '0';
        maindec_mem_read_mem     <= '0';
        maindec_mem_size_mem     <= MEM_WORD;
        maindec_mem_unsigned_mem <= '0';
      else
        maindec_reg_write_mem    <= maindec_reg_write_ex;
        maindec_result_src_mem   <= maindec_result_src_ex;
        maindec_mem_write_mem    <= maindec_mem_write_ex;
        maindec_mem_read_mem     <= maindec_mem_read_ex;
        maindec_mem_size_mem     <= maindec_mem_size_ex;
        maindec_mem_unsigned_mem <= maindec_mem_unsigned_ex;
      end if;
    end if;
  end process p_ctrl_e_to_m_reg;

  -- Purpose: M->W control pipeline register. Captures writeback mux select and
  -- load sign/size metadata for the W stage.
  p_ctrl_m_to_w_reg : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        maindec_reg_write_wb    <= '0';
        maindec_result_src_wb   <= WB_ALU;
        maindec_mem_size_wb     <= MEM_WORD;
        maindec_mem_unsigned_wb <= '0';
      else
        maindec_reg_write_wb    <= maindec_reg_write_mem;
        maindec_result_src_wb   <= maindec_result_src_mem;
        maindec_mem_size_wb     <= maindec_mem_size_mem;
        maindec_mem_unsigned_wb <= maindec_mem_unsigned_mem;
      end if;
    end if;
  end process p_ctrl_m_to_w_reg;

  ALUControlE  <= aludec_alu_control_ex;
  SrcASelE     <= maindec_src_a_sel_ex;
  ALUSrcBE     <= maindec_alu_src_ex;
  BranchOpE    <= maindec_branch_op_ex;
  JalrE        <= maindec_jalr_ex;
  JumpE        <= maindec_jump_ex;

  MemWriteM    <= maindec_mem_write_mem;
  MemReadM     <= maindec_mem_read_mem;
  MemSizeM     <= maindec_mem_size_mem;
  MemUnsignedM <= maindec_mem_unsigned_mem;
  RegWriteM    <= maindec_reg_write_mem;
  RegWriteE    <= maindec_reg_write_ex;

  RegWriteW    <= maindec_reg_write_wb;
  ResultSrcW   <= maindec_result_src_wb;
  MemSizeW     <= maindec_mem_size_wb;
  MemUnsignedW <= maindec_mem_unsigned_wb;
end architecture rtl;
