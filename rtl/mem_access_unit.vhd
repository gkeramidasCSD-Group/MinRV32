-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   ARCHITECTURE-LOCAL FUNCTIONS  Functions declared inside an architecture
--       (before 'begin') are visible only within that file. This keeps
--       byte_enable() and align_store() private to the memory-access block
--       rather than polluting the global core_pkg namespace.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: mem_access_unit
-- Bundles the byte-enable generation and store alignment so the memory stage
-- appears as one semantic block in the hierarchy. Load extension is applied
-- separately in the writeback stage (writeback_stage.vhd).
-- ============================================================================
entity mem_access_unit is
  port (
    alu_result   : in  word_t;
    rs2_data     : in  word_t;
    mem_size     : in  std_logic_vector(1 downto 0);
    mem_write    : in  std_logic;
    mem_read     : in  std_logic;
    store_data   : out word_t;
    byte_strobes : out std_logic_vector(3 downto 0);
    write_en     : out std_logic;
    read_en      : out std_logic
  );
end entity mem_access_unit;

architecture rtl of mem_access_unit is

  -- Localized memory helpers: only this block requires byte enables and
  -- store-data alignment so we keep the functions here.

  -- byte_enable:
  --   Decodes store size + byte address into a four-bit strobe that the
  --   dmem uses to update only the addressed byte lanes (SB/SH/SW).
  --   Without it the byte-addressable write behavior would be lost.
  function byte_enable(
    addr : std_logic_vector(1 downto 0);
    size : std_logic_vector(1 downto 0)
  ) return byte_en_t is
    variable be  : byte_en_t := (others => '0');
  begin
    case size is
      when MEM_BYTE =>
        case addr is
          when "00" => be := "0001";
          when "01" => be := "0010";
          when "10" => be := "0100";
          when "11" => be := "1000";
          when others => be := (others => '0');
        end case;
      when MEM_HALF =>
        if addr(1) = '0' then
          be := "0011";
        else
          be := "1100";
        end if;
      when others =>
        be := "1111";
    end case;
    return be;
  end function;

  -- align_store:
  --   Shifts RS2 data into the byte lane indicated by the low address bits.
  --   DMEM sees only word writes, so we need to reposition SB/SH payloads
  --   into the correct byte lanes before presenting them to memory.
  function align_store(
    data : word_t;
    addr : std_logic_vector(1 downto 0);
    size : std_logic_vector(1 downto 0)
  ) return word_t is
    variable res : word_t := (others => '0');
  begin
    case size is
      when MEM_BYTE =>
        case addr is
          when "00" => res(7 downto 0)   := data(7 downto 0);
          when "01" => res(15 downto 8)  := data(7 downto 0);
          when "10" => res(23 downto 16) := data(7 downto 0);
          when others => res(31 downto 24) := data(7 downto 0);
        end case;
      when MEM_HALF =>
        if addr(1) = '0' then
          res(15 downto 0) := data(15 downto 0);
        else
          res(31 downto 16) := data(15 downto 0);
        end if;
      when others =>
        res := data;
    end case;
    return res;
  end function;

begin
  store_data <= align_store(rs2_data, alu_result(1 downto 0), mem_size);
  byte_strobes <= byte_enable(alu_result(1 downto 0), mem_size) when mem_write = '1' else (others => '0');
  -- The reason mem_write and mem_read are routed through this entity
  -- rather than wired directly at the parent level is encapsulation:
  -- from the parent's perspective, everything memory-related
  -- (data, strobes, and enables) comes out of one block.
  write_en <= mem_write;
  read_en  <= mem_read;
end architecture rtl;
