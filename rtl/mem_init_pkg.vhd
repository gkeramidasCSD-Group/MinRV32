-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   PACKAGE (shared subprograms)  Centralizes a small helper used by multiple
--       memory models so the file I/O template stays consistent.
--
--   IMPURE FUNCTION + TEXTIO  init_mem() performs elaboration-time file I/O to
--       preload a memory array. Both simulation (GHDL) and synthesis (Vivado)
--       execute the function at elaboration time; Vivado then bakes the
--       returned array into the inferred BRAM's INIT_xx parameters, so the
--       program is present in the bitstream without any tool-specific
--       INIT_FILE attribute.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_textio.all;
library std;
use std.textio.all;
use work.core_pkg.all;

package mem_init_pkg is
  type word_mem_t is array (natural range <>) of word_t;

  impure function init_mem(
    file_name : string;
    words     : positive
  ) return word_mem_t;
end package mem_init_pkg;

package body mem_init_pkg is

  -- init_mem: elaboration-time hex loader for simulation memory models.
  --
  -- WHY IMPURE?
  --   A pure function in VHDL may only depend on its arguments and must
  --   produce identical results for identical inputs.  init_mem reads an
  --   external file (a side-effect outside the function's argument list),
  --   so the result can differ between calls with the same arguments (e.g.
  --   if the file changes).  The "impure" keyword is therefore mandatory;
  --   without it the compiler rejects any file-I/O inside the function body.
  --
  -- WHAT IT DOES:
  --   Called once per memory model (imem_dp, dmem) during VHDL elaboration
  --   to pre-populate the constant/signal that backs the BRAM array.  It
  --   opens a plain-text hex file (one 32-bit word per line, e.g. the .hex
  --   produced by the linker/objcopy flow), reads up to `words` entries, and
  --   returns an initialized word_mem_t array.  Words beyond the last hex
  --   line remain 0x00000000.
  --
  -- SYNTHESIS:
  --   Vivado's elaborator supports VHDL TEXTIO at elaboration time: it opens
  --   the hex file, reads the words, and bakes the resulting array into the
  --   inferred BRAM's INIT_xx parameters of the bitstream.  No tool-specific
  --   INIT_FILE attribute is needed.  The same code path runs under GHDL for
  --   simulation, so the two flows stay in lockstep.
  --
  -- EMPTY / MISSING FILE:
  --   Passing an empty string skips the open attempt and returns a zeroed
  --   array (allows instantiation without an init file).  A failed open also
  --   silently returns zeros, avoiding a fatal elaboration error in
  --   stand-alone unit tests that do not supply a hex image.

  impure function init_mem(
    file_name : string;
    words     : positive
  ) return word_mem_t is
    variable mem_v  : word_mem_t(words - 1 downto 0) := (others => (others => '0'));
    file f          : text;
    variable status : file_open_status;
    variable l      : line;
    variable idx    : integer := 0;
    variable value  : std_logic_vector(31 downto 0);
  begin
    if file_name'length = 0 then
      return mem_v;
    end if;

    file_open(status, f, file_name, read_mode);
    if status /= open_ok then
      return mem_v;
    end if;
    while not endfile(f) loop
      exit when idx >= words;
      readline(f, l);
      if l'length = 0 then          -- skip blank lines
        next;
      end if;
      hread(l, value);              -- parse one 8-digit hex word
      mem_v(idx) := value;
      idx := idx + 1;
    end loop;
    file_close(f);

    return mem_v;
  end function init_mem;
end package body mem_init_pkg;
