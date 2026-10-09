-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   ARCHITECTURE-LOCAL FUNCTION  The `src_a_sel_vec` conversion function is
--       declared inside the architecture (before `begin`) and is visible only
--       within this file. It converts the SrcASel_t enum to a 2-bit
--       std_logic_vector for the generic mux3, avoiding a package-level
--       dependency for a single-use helper.
--
--   FORWARDING MUX CASCADE  Two mux3 instances select between the register-
--       file output, the M-stage result, and the W-stage result. A second
--       mux layer then selects between the forwarded value and the PC or zero
--       for ALU operand A. This cascade resolves data hazards without stalls.
-- ============================================================================

-- ============================================================================
-- Entity: execute_stage
-- Execute pipeline stage wrapper. Contains D->E pipeline registers, forwarding
-- muxes, ALU operand selection muxes, ALU, branch unit, and branch/JALR
-- target computation. Each sub-component is a named instantiation visible in
-- Vivado's elaborated design.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

entity execute_stage is
  port (
    clk             : in  std_logic;
    rst             : in  std_logic;
    -- Pipeline control.
    FlushE          : in  std_logic;
    ForwardAE       : in  std_logic_vector(1 downto 0);
    ForwardBE       : in  std_logic_vector(1 downto 0);
    ALUControlE     : in  ALUControl_t;
    SrcASelE        : in  SrcASel_t;
    ALUSrcBE        : in  std_logic;
    BranchOpE       : in  BranchOp_t;
    -- From decode stage (pipeline register inputs).
    rs1_data_d      : in  word_t;
    rs2_data_d      : in  word_t;
    pc_d            : in  word_t;
    imm_d           : in  word_t;
    pc_plus4_d      : in  word_t;
    rd_d            : in  std_logic_vector(4 downto 0);
    rs1_addr_d      : in  std_logic_vector(4 downto 0);
    rs2_addr_d      : in  std_logic_vector(4 downto 0);
    -- Forwarding inputs from later stages.
    alu_result_m    : in  word_t;
    wb_result_w     : in  word_t;
    -- Register address outputs (to hazard unit).
    rs1_e           : out std_logic_vector(4 downto 0);
    rs2_e           : out std_logic_vector(4 downto 0);
    rd_e            : out std_logic_vector(4 downto 0);
    -- Branch evaluation output.
    zero_e          : out std_logic;
    -- Pipeline outputs to memory stage.
    alu_result_e    : out word_t;
    write_data_e    : out word_t;
    pc_plus4_e      : out word_t;
    -- Branch/jump targets (to fetch stage).
    branch_target_e : out word_t;
    jalr_target_e   : out word_t
  );
end entity execute_stage;

architecture rtl of execute_stage is
  subtype slv2_t is std_logic_vector(1 downto 0);

  function src_a_sel_vec(sel : SrcASel_t) return slv2_t is
  begin
    case sel is
      when OPA_RS1  => return "00";
      when OPA_PC   => return "01";
      when OPA_ZERO => return "10";
    end case;
  end function;

  -- Registered D->E outputs.
  signal rs1_data_e      : word_t;
  signal rs2_data_e      : word_t;
  signal pc_e            : word_t;
  signal imm_e           : word_t;
  signal pc_plus4_e_i    : word_t;
  -- Post-forwarding values.
  signal fwd_rs1_data_e  : word_t;
  signal fwd_rs2_data_e  : word_t;
  -- ALU operands.
  signal alu_src_a_e     : word_t;
  signal alu_src_b_e     : word_t;
  signal alu_result_e_i  : word_t;
  -- JALR target.
  signal jalr_target_raw : word_t;
  signal srca_sel_slv    : slv2_t;
begin

  -- ====================================================================
  -- D->E Pipeline Registers
  -- ====================================================================
  de_rs1_data_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => rs1_data_d, q => rs1_data_e);

  de_rs2_data_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => rs2_data_d, q => rs2_data_e);

  de_pc_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => pc_d, q => pc_e);

  de_imm_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => imm_d, q => imm_e);

  de_pc_plus4_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => pc_plus4_d, q => pc_plus4_e_i);

  de_rs1_addr_reg : entity work.pipe_reg
    generic map (WIDTH => 5)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => rs1_addr_d, q => rs1_e);

  de_rs2_addr_reg : entity work.pipe_reg
    generic map (WIDTH => 5)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => rs2_addr_d, q => rs2_e);

  de_rd_reg : entity work.pipe_reg
    generic map (WIDTH => 5)
    port map (clk => clk, rst => rst, flush => FlushE, stall => '0',
              d => rd_d, q => rd_e);

  -- ====================================================================
  -- Forwarding Muxes
  -- ====================================================================
  mux_a_fwd : entity work.mux3
    generic map (WIDTH => XLEN)
    port map (
      d0 => rs1_data_e,
      d1 => wb_result_w,
      d2 => alu_result_m,
      s  => ForwardAE,
      y  => fwd_rs1_data_e
    );

  mux_b_fwd : entity work.mux3
    generic map (WIDTH => XLEN)
    port map (
      d0 => rs2_data_e,
      d1 => wb_result_w,
      d2 => alu_result_m,
      s  => ForwardBE,
      y  => fwd_rs2_data_e
    );

  -- ====================================================================
  -- ALU Source Muxes
  -- ====================================================================
  srca_sel_slv <= src_a_sel_vec(SrcASelE);

  mux_a_sel : entity work.mux3
    generic map (WIDTH => XLEN)
    port map (
      d0 => fwd_rs1_data_e,
      d1 => pc_e,
      d2 => (others => '0'),
      s  => srca_sel_slv,
      y  => alu_src_a_e
    );

  mux_b_sel : entity work.mux2
    generic map (WIDTH => XLEN)
    port map (
      d0 => fwd_rs2_data_e,
      d1 => imm_e,
      s  => ALUSrcBE,
      y  => alu_src_b_e
    );

  -- ====================================================================
  -- ALU
  -- ====================================================================
  alu_inst : entity work.alu
    port map (
      op     => ALUControlE,
      a      => alu_src_a_e,
      b      => alu_src_b_e,
      result => alu_result_e_i
    );

  -- ====================================================================
  -- Branch Unit
  -- ====================================================================
  branch_inst : entity work.branch_unit
    port map (
      op       => BranchOpE,
      rs1_data => fwd_rs1_data_e,
      rs2_data => fwd_rs2_data_e,
      taken    => zero_e
    );

  -- ====================================================================
  -- Target Computation
  -- ====================================================================
  branch_target_e <= std_logic_vector(unsigned(pc_e) + unsigned(imm_e));
  jalr_target_raw <= std_logic_vector(unsigned(fwd_rs1_data_e) + unsigned(imm_e));
  jalr_target_e   <= jalr_target_raw(31 downto 1) & '0';

  -- Output assignments.
  alu_result_e <= alu_result_e_i;
  write_data_e <= fwd_rs2_data_e;
  pc_plus4_e   <= pc_plus4_e_i;

end architecture rtl;
