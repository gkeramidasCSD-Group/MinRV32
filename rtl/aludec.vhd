-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   NESTED CASE  The ALU decoder uses an outer case on ALUOp (from maindec)
--       and an inner case on funct3/funct7. This two-level decode is a
--       textbook pattern for RISC-V ALU control generation.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: aludec
-- Two-level ALU control decoder. The outer case on ALUOp distinguishes
-- load/store/branch (ALU_ADD or ALU_SUB) from arithmetic/logic instructions
-- (funct3/funct7b5-based). Outputs ALUControl_t for the execute-stage ALU.
-- ============================================================================
entity aludec is
  port (
    opb5       : in  std_logic;
    funct3     : in  std_logic_vector(2 downto 0);
    funct7b5   : in  std_logic;
    alu_op     : in  std_logic_vector(1 downto 0);
    alu_control : out ALUControl_t
  );
end entity aludec;

architecture rtl of aludec is
  signal rtype_sub : std_logic;
begin
  rtype_sub <= funct7b5 and opb5;

  -- Purpose: ALU control decode (combinational). Translates ALUOp plus funct
  -- fields into the ALUControl_t enum used by ALU in the Execute stage.
  p_aludec : process(alu_op, funct3, funct7b5, rtype_sub)
  begin
    case alu_op is
      when "00" =>
        alu_control <= ALU_ADD;
      when "01" =>
        alu_control <= ALU_SUB;
      when others =>
        case funct3 is
          when "000" =>
            if rtype_sub = '1' then
              alu_control <= ALU_SUB;
            else
              alu_control <= ALU_ADD;
            end if;
          when "001" => alu_control <= ALU_SLL;
          when "010" => alu_control <= ALU_SLT;
          when "011" => alu_control <= ALU_SLTU;
          when "100" => alu_control <= ALU_XOR;
          when "101" =>
            if funct7b5 = '1' then
              alu_control <= ALU_SRA;
            else
              alu_control <= ALU_SRL;
            end if;
          when "110" => alu_control <= ALU_OR;
          when "111" => alu_control <= ALU_AND;
          when others =>
            alu_control <= ALU_ADD;
        end case;
    end case;
  end process p_aludec;
end architecture rtl;
