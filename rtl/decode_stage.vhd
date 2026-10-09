-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   BRAM FLUSH COMPENSATION  Because the instruction BRAM uses synchronous
--       reads, its output appears one cycle *after* the address changes. When
--       a pipeline flush fires, the BRAM is already reading the wrong address.
--       A one-cycle "flush hold" register remembers the flush and muxes a NOP
--       over the BRAM output on the following cycle, effectively inserting a
--       pipeline bubble without requiring the BRAM to support asynchronous clear.
--
--   BIT-FIELD EXTRACTION  RISC-V instruction fields (opcode, funct3, rs1, rs2,
--       rd) are extracted with simple slice assignments -- a common VHDL pattern
--       for decoding packed bus formats.
-- ============================================================================

-- ============================================================================
-- Entity: decode_stage
-- Decode pipeline stage wrapper. Contains the BRAM flush-hold register,
-- instruction NOP mux, F->D PC pipeline registers, register file, and
-- immediate extension unit. Each sub-component is a named instantiation
-- visible in Vivado's elaborated design.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

entity decode_stage is
  port (
    clk         : in  std_logic;
    rst         : in  std_logic;
    -- Pipeline control.
    StallD      : in  std_logic;
    FlushD      : in  std_logic;
    ImmSrcD     : in  ImmSrc_t;
    -- From fetch stage.
    pc_f        : in  word_t;
    pc_plus4_f  : in  word_t;
    -- From instruction memory (BRAM registered output).
    imem_rdata  : in  word_t;
    -- From writeback stage (regfile write port).
    RegWriteW   : in  std_logic;
    rd_w        : in  std_logic_vector(4 downto 0);
    wb_result_w : in  word_t;
    -- Instruction decode outputs (to controller).
    op_d        : out std_logic_vector(6 downto 0);
    funct3_d    : out std_logic_vector(2 downto 0);
    funct7b5_d  : out std_logic;
    -- Register addresses (to hazard unit & next stage).
    rs1_d       : out std_logic_vector(4 downto 0);
    rs2_d       : out std_logic_vector(4 downto 0);
    -- Pipeline outputs to execute stage.
    rs1_data_d  : out word_t;
    rs2_data_d  : out word_t;
    imm_d       : out word_t;
    rd_d        : out std_logic_vector(4 downto 0);
    pc_d        : out word_t;
    pc_plus4_d  : out word_t
  );
end entity decode_stage;

architecture rtl of decode_stage is
  constant NOP_INSTR : word_t := x"00000013"; -- addi x0, x0, 0

  -- BRAM flush-hold: when FlushD fires the BRAM is already reading
  -- next-PC data that is stale. We register the flush condition here and
  -- mux a NOP over the BRAM output on the *following* cycle.
  signal flush_d_hold  : std_logic := '1';
  signal imem_instr_id : word_t := NOP_INSTR;
begin

  -- Flush-hold register (resets to '1' - special, cannot use pipe_reg).
  p_flush_d_hold_reg : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        flush_d_hold <= '1';
      elsif StallD = '0' then
        flush_d_hold <= FlushD;
      end if;
    end if;
  end process p_flush_d_hold_reg;

  -- Instruction mux: BRAM output or NOP (bubble).
  imem_instr_id <= NOP_INSTR when flush_d_hold = '1' else imem_rdata;

  -- F->D PC pipeline register.
  fd_pc_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (
      clk   => clk,
      rst   => rst,
      flush => FlushD,
      stall => StallD,
      d     => pc_f,
      q     => pc_d
    );

  -- F->D PC+4 pipeline register.
  fd_pc_plus4_reg : entity work.pipe_reg
    generic map (WIDTH => XLEN)
    port map (
      clk   => clk,
      rst   => rst,
      flush => FlushD,
      stall => StallD,
      d     => pc_plus4_f,
      q     => pc_plus4_d
    );

  -- Instruction field extraction.
  op_d       <= imem_instr_id(6 downto 0);
  funct3_d   <= imem_instr_id(14 downto 12);
  funct7b5_d <= imem_instr_id(30);
  rs1_d      <= imem_instr_id(19 downto 15);
  rs2_d      <= imem_instr_id(24 downto 20);
  rd_d       <= imem_instr_id(11 downto 7);

  -- Register file.
  regfile_inst : entity work.regfile
    port map (
      clk      => clk,
      rs1_addr => rs1_d,
      rs2_addr => rs2_d,
      rd_addr  => rd_w,
      rd_data  => wb_result_w,
      rd_write => RegWriteW,
      rs1_data => rs1_data_d,
      rs2_data => rs2_data_d
    );

  -- Immediate extension.
  imm_inst : entity work.extend
    port map (
      instr   => imem_instr_id,
      sel     => ImmSrcD,
      imm_out => imm_d
    );

end architecture rtl;
