-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   COMBINATIONAL UNIT TEST  mem_access_unit is purely combinational, so this
--       TB applies inputs, waits a short time for signal updates, then asserts
--       on outputs.
--
--   PROCEDURE-DRIVEN VECTORS  check() captures repeated stimulus/expectation
--       logic so each test case reads like a spec example (SB/SH/SW alignment,
--       byte-enable generation, write/read enable passthrough).
--
--   ADDRESS LANE REASONING  The low two address bits (alu_result(1 downto 0))
--       select byte lanes within a word; the expected store_data/strobes
--       demonstrate how sub-word stores are packed.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
library std;
use std.env.all;
use work.core_pkg.all;

entity tb_mem_access_unit is
end entity tb_mem_access_unit;

architecture sim of tb_mem_access_unit is
  signal alu_result   : word_t := (others => '0');
  signal rs2_data     : word_t := (others => '0');
  signal mem_size     : std_logic_vector(1 downto 0) := MEM_WORD;
  signal mem_write    : std_logic := '0';
  signal mem_read     : std_logic := '0';
  signal store_data   : word_t;
  signal byte_strobes : std_logic_vector(3 downto 0);
  signal write_en     : std_logic;
  signal read_en      : std_logic;

  -- Apply one stimulus vector and check that:
  --   store_data   = rs2_data shifted into the correct byte lane(s)
  --   byte_strobes = one-hot (SB), two-bit (SH), or all-ones (SW) mask
  --   write_en     = mem_write passthrough
  --   read_en      = mem_read  passthrough
  procedure check(
    signal alu_s   : inout word_t;                     -- drives alu_result
    signal size_s  : out std_logic_vector(1 downto 0); -- drives mem_size
    signal w_s     : out std_logic;                    -- drives mem_write
    signal r_s     : out std_logic;                    -- drives mem_read
    signal store_s : in  word_t;                       -- observed store_data
    signal be_s    : in  std_logic_vector(3 downto 0); -- observed byte_strobes
    signal we_s    : in  std_logic;                    -- observed write_en
    signal re_s    : in  std_logic;                    -- observed read_en
    addr_low       : std_logic_vector(1 downto 0);     -- value for alu_result(1:0)
    size_in        : std_logic_vector(1 downto 0);     -- value for mem_size
    w_in           : std_logic;                        -- value for mem_write
    r_in           : std_logic;                        -- value for mem_read
    exp_store      : word_t;                           -- expected store_data
    exp_be         : std_logic_vector(3 downto 0);     -- expected byte_strobes
    label_in       : string                            -- test-case name
  ) is
  begin
    alu_s(1 downto 0) <= addr_low;
    size_s <= size_in;
    w_s <= w_in;
    r_s <= r_in;
    wait for 1 ns;
    assert store_s = exp_store report "store_data mismatch (" & label_in & ")" severity error;
    assert be_s = exp_be report "byte_strobes mismatch (" & label_in & ")" severity error;
    assert we_s = w_in report "write_en mismatch (" & label_in & ")" severity error;
    assert re_s = r_in report "read_en mismatch (" & label_in & ")" severity error;
  end procedure;
begin
  dut : entity work.mem_access_unit
    port map (
      alu_result   => alu_result,
      rs2_data     => rs2_data,
      mem_size     => mem_size,
      mem_write    => mem_write,
      mem_read     => mem_read,
      store_data   => store_data,
      byte_strobes => byte_strobes,
      write_en     => write_en,
      read_en      => read_en
    );

  stim : process
  begin
    rs2_data <= x"a1b2c3d4";

    -- SW: no alignment shift, all bytes enabled.
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "00", MEM_WORD, '1', '0', x"a1b2c3d4", "1111", "sw @00");
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "11", MEM_WORD, '1', '0', x"a1b2c3d4", "1111", "sw @11");

    -- SB: move low byte into lane; one-hot strobes.
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "00", MEM_BYTE, '1', '0', x"000000d4", "0001", "sb @00");
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "01", MEM_BYTE, '1', '0', x"0000d400", "0010", "sb @01");
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "10", MEM_BYTE, '1', '0', x"00d40000", "0100", "sb @10");
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "11", MEM_BYTE, '1', '0', x"d4000000", "1000", "sb @11");

    -- SH: move low halfword into lane; two-bit strobes.
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "00", MEM_HALF, '1', '0', x"0000c3d4", "0011", "sh @00");
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "10", MEM_HALF, '1', '0', x"c3d40000", "1100", "sh @10");

    -- When mem_write is deasserted, byte strobes must be 0.
    check(alu_result, mem_size, mem_write, mem_read, store_data, byte_strobes, write_en, read_en,
          "00", MEM_BYTE, '0', '1', x"000000d4", "0000", "no write strobes");

    report "tb_mem_access_unit: PASS" severity note;
    finish;
  end process;
end architecture sim;
