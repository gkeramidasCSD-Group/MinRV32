-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   NESTED CASE + VARIABLE  The process uses a case on mem_size with a nested
--       case on addr_lsb to select the correct byte or halfword from the BRAM
--       output word. Variables (byte_val, half_val) hold intermediate values
--       that are read in the same sequential context -- something signals
--       cannot do within a single process.
--
--   RESIZE (sign extension)  `resize(signed(byte_val), XLEN)` sign-extends an
--       8-bit value to 32 bits by replicating the MSB. For unsigned loads the
--       upper bits are left as zero (the default initialization of `res`).
-- ============================================================================

-- ============================================================================
-- Entity: load_extend_unit
-- Combinational load-data extension for byte/halfword/word loads with
-- optional sign extension. Extracted from the datapath so it appears as a
-- distinct block in Vivado's elaborated design schematic.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

entity load_extend_unit is
  port (
    data        : in  word_t;
    addr_lsb    : in  std_logic_vector(1 downto 0);
    mem_size    : in  std_logic_vector(1 downto 0);
    is_unsigned : in  std_logic;
    result      : out word_t
  );
end entity load_extend_unit;

architecture rtl of load_extend_unit is
begin
  p_load_extend : process(data, addr_lsb, mem_size, is_unsigned)
    variable res      : word_t := (others => '0');
    variable byte_val : byte_t;
    variable half_val : halfword_t;
  begin
    res := (others => '0');
    case mem_size is
      when MEM_BYTE =>
        case addr_lsb is
          when "00"   => byte_val := data(7 downto 0);
          when "01"   => byte_val := data(15 downto 8);
          when "10"   => byte_val := data(23 downto 16);
          when others => byte_val := data(31 downto 24);
        end case;
        if is_unsigned = '1' then
          res(7 downto 0) := byte_val;
        else
          res := std_logic_vector(resize(signed(byte_val), XLEN));
        end if;
      when MEM_HALF =>
        if addr_lsb(1) = '0' then
          half_val := data(15 downto 0);
        else
          half_val := data(31 downto 16);
        end if;
        if is_unsigned = '1' then
          res(15 downto 0) := half_val;
        else
          res := std_logic_vector(resize(signed(half_val), XLEN));
        end if;
      when others =>
        res := data;
    end case;
    result <= res;
  end process p_load_extend;
end architecture rtl;
