-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   RESIZE (sign extension)  ieee.numeric_std.resize() extends a signed value
--       to a wider width by replicating the MSB (sign bit). This is exactly
--       the hardware operation that sign-extends RISC-V immediates to 32 bits.
--
--   BIT CONCATENATION  The '&' operator joins bit vectors end-to-end. The
--       RV32I immediate formats scatter bits across the instruction word;
--       concatenation reassembles them in the correct order before resize.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: extend
-- Extracts and sign-extends the RV32I immediates. The control unit supplies
-- `ImmSrc_t` so each instruction sees the properly aligned constant.
-- IMM usage: IMM_I (OP-IMM/loads/JALR), IMM_S (stores), IMM_B (branches),
-- IMM_U (LUI/AUIPC), IMM_J (JAL).
-- ============================================================================

entity extend is
  port (
    instr   : in  word_t;
    sel     : in  ImmSrc_t;
    imm_out : out word_t
  );
end entity extend;

architecture rtl of extend is
begin
  -- Purpose: Immediate extraction and sign extension (combinational). Reassembles
  -- the selected immediate encoding and extends it to 32 bits.
  p_imm_extend : process(instr, sel)
    variable imm : signed(word_t'range);
    variable bits : std_logic_vector(31 downto 0);
  begin
    bits := instr;
    case sel is
      when IMM_I =>
        -- I-type imm: bits[31:20] sign-extended.
        imm := resize(signed(bits(31 downto 20)), 32);
      when IMM_S =>
        -- S-type: combine store high/low fields.
        imm := resize(signed(bits(31 downto 25) & bits(11 downto 7)), 32);
      when IMM_B =>
        -- B-type: branch offset with implicit bit[0]=0.
        imm := resize(signed(bits(31) & bits(7) & bits(30 downto 25) & bits(11 downto 8) & '0'), 32);
      when IMM_U =>
        -- U-type: upper immediate forms high 20 bits.
        imm := signed(bits(31 downto 12) & x"000");
      when IMM_J =>
        -- J-type: reorder JAL/J imm per spec and append zero LSB.
        imm := resize(signed(bits(31) & bits(19 downto 12) & bits(20) & bits(30 downto 21) & '0'), 32);
    end case;
    imm_out <= std_logic_vector(imm);
  end process p_imm_extend;
end architecture rtl;
