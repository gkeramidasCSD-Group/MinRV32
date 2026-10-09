-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   CASE with ENUMERATION TYPES  The main decoder uses a VHDL case statement
--       on a 7-bit opcode. Each branch sets multiple output signals at once
--       -- exactly how a truth-table-style decoder is written in VHDL.
--       Because the process sensitivity list is complete, synthesis produces
--       purely combinational logic (no latches).
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: maindec
-- Textbook-style main decoder with RV32I extensions. Generates high-level
-- control signals plus ALUOp for aludec.
-- ============================================================================

entity maindec is
  port (
    op           : in  std_logic_vector(6 downto 0);
    funct3       : in  std_logic_vector(2 downto 0);
    result_src   : out ResultSrc_t;
    mem_write    : out std_logic;
    mem_read     : out std_logic;
    branch       : out std_logic;
    alu_src      : out std_logic;
    reg_write    : out std_logic;
    jump         : out std_logic;
    jalr         : out std_logic;
    imm_src      : out ImmSrc_t;
    alu_op       : out std_logic_vector(1 downto 0);
    mem_size     : out std_logic_vector(1 downto 0);
    mem_unsigned : out std_logic;
    branch_op    : out BranchOp_t;
    src_a_sel    : out SrcASel_t
  );
end entity maindec;

architecture rtl of maindec is
begin
  -- Purpose: Main control decode (combinational). Generates high-level control
  -- signals, immediate format selection, and ALUOp for the ALU decoder.
  p_maindec : process(op, funct3)
  begin
    -- Defaults mirror the textbook "safe" control word.
    result_src   <= WB_ALU;
    mem_write    <= '0';
    mem_read     <= '0';
    branch       <= '0';
    alu_src      <= '0';
    reg_write    <= '0';
    jump         <= '0';
    jalr         <= '0';
    imm_src      <= IMM_I;
    alu_op       <= "00";
    mem_size     <= MEM_WORD;
    mem_unsigned <= '0';
    branch_op    <= BR_NONE;
    src_a_sel    <= OPA_RS1;

    case op is
      when "0110111" =>  -- LUI
        reg_write <= '1';
        src_a_sel <= OPA_ZERO;
        alu_src   <= '1';
        imm_src   <= IMM_U;
        alu_op    <= "00";
      when "0010111" =>  -- AUIPC
        reg_write <= '1';
        src_a_sel <= OPA_PC;
        alu_src   <= '1';
        imm_src   <= IMM_U;
        alu_op    <= "00";
      when "1101111" =>  -- JAL
        reg_write  <= '1';
        result_src <= WB_PC4;
        jump       <= '1';
        imm_src    <= IMM_J;
        src_a_sel  <= OPA_PC;
        alu_src    <= '1';
        alu_op     <= "00";
      when "1100111" =>  -- JALR
        reg_write  <= '1';
        result_src <= WB_PC4;
        jump       <= '1';
        jalr       <= '1';
        imm_src    <= IMM_I;
        src_a_sel  <= OPA_RS1;
        alu_src    <= '1';
        alu_op     <= "00";
      when "1100011" =>  -- Branches
        branch  <= '1';
        imm_src <= IMM_B;
        alu_op  <= "01";
        case funct3 is
          when "000" => branch_op <= BR_EQ;
          when "001" => branch_op <= BR_NE;
          when "100" => branch_op <= BR_LT;
          when "101" => branch_op <= BR_GE;
          when "110" => branch_op <= BR_LTU;
          when "111" => branch_op <= BR_GEU;
          when others => branch_op <= BR_NONE;
        end case;
      when "0000011" =>  -- Loads
        reg_write  <= '1';
        mem_read   <= '1';
        result_src <= WB_MEM;
        src_a_sel  <= OPA_RS1;
        alu_src    <= '1';
        imm_src    <= IMM_I;
        alu_op     <= "00";
        case funct3 is
          when "000" =>
            mem_size     <= MEM_BYTE;
            mem_unsigned <= '0';
          when "001" =>
            mem_size     <= MEM_HALF;
            mem_unsigned <= '0';
          when "010" =>
            mem_size     <= MEM_WORD;
            mem_unsigned <= '0';
          when "100" =>
            mem_size     <= MEM_BYTE;
            mem_unsigned <= '1';
          when "101" =>
            mem_size     <= MEM_HALF;
            mem_unsigned <= '1';
          when others =>
            mem_size     <= MEM_WORD;
            mem_unsigned <= '0';
        end case;
      when "0100011" =>  -- Stores
        mem_write <= '1';
        src_a_sel <= OPA_RS1;
        alu_src   <= '1';
        imm_src   <= IMM_S;
        alu_op    <= "00";
        case funct3 is
          when "000" => mem_size <= MEM_BYTE;
          when "001" => mem_size <= MEM_HALF;
          when others => mem_size <= MEM_WORD;
        end case;
      when "0010011" =>  -- OP-IMM
        reg_write <= '1';
        src_a_sel <= OPA_RS1;
        alu_src   <= '1';
        imm_src   <= IMM_I;
        alu_op    <= "10";
      when "0110011" =>  -- OP
        reg_write <= '1';
        src_a_sel <= OPA_RS1;
        alu_src   <= '0';
        alu_op    <= "10";
      when others =>
        null;
    end case;
  end process p_maindec;
end architecture rtl;
