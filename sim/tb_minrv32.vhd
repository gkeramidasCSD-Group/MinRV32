-- ============================================================================
-- VHDL Concepts Demonstrated in this file:
--
--   SELF-CHECKING TESTBENCH  The testbench decides pass/fail on its own using
--       assertions, rather than relying on waveform inspection.
--
--   GENERICS (TB configuration)  File paths, signature-window size, cycle
--       limit, and trace enable are all generics so the same TB can run many
--       programs without editing source code.
--
--   IMPURE FUNCTION + TEXTIO  load_words() uses std.textio +
--       ieee.std_logic_textio.hread() to read hex files at simulation time.
--       Impure functions are allowed to access external state (files).
--
--   PROCEDURES for formatting  write_asm(), write_kv(), etc. keep the trace
--       printing readable and avoid duplicated string concatenation.
--
--   CLOCK/RESET GENERATION  A free-running clock uses wait-for delays; reset
--       is applied for a fixed number of cycles.
--
--   SIMULATION CONTROL  std.env.stop/finish end the simulation cleanly on
--       pass or after printing a failure reason.
--
--   SAFE TYPE CONVERSIONS  addr_valid() is used before casting std_logic_vector
--       to unsigned/signed, preventing metavalue (X/U/Z) conversion surprises.
-- ============================================================================

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.std_logic_textio.all;
library std;
use std.textio.all;
use std.env.all;
use work.core_pkg.all;

-- ============================================================================
-- Entity: tb_minrv32
-- Self-checking testbench for the MinRV32 pipelined core. Loads hex files,
-- watches the DMEM signature window by snooping stores, and stops on success
-- or when MAX_CYCLES elapses.
-- ============================================================================

entity tb_minrv32 is
  generic (
    IMEM_INIT_FILE : string := "build/prog.text.hex";
    DMEM_INIT_FILE : string := "build/prog.data.hex";
    EXPECTED_FILE  : string := "";
    STRICT_FILES   : boolean := false;
    SIGNATURE_ADDR : natural := 16#20000100#;
    SIGNATURE_WORDS: natural := 1;
    MAX_CYCLES     : natural := 2000;
    HALT_ON_PASS   : boolean := true;
    TRACE_ENABLE   : boolean := false;
    FORWARDING_ENABLE : boolean := true
  );
end entity tb_minrv32;

architecture sim of tb_minrv32 is
  constant CLK_PERIOD : time := 10 ns;
  constant IMEM_WORDS : natural := 2048;
  constant DMEM_WORDS : natural := 2048;
  constant DMEM_BASE_INT : natural := 16#20000000#;
  constant DMEM_BASE : unsigned(31 downto 0) := to_unsigned(DMEM_BASE_INT, 32);

  type word_array_t is array (natural range <>) of word_t;

  -- Hex loader shared by DMEM/signature arrays. By default missing files
  -- report a warning and return zeroed memories so the TB can still run.
  -- Set STRICT_FILES=true to make missing files a hard failure.
  impure function load_words(
    file_name : string;
    length    : natural
  ) return word_array_t is
    file f     : text;
    variable status : file_open_status;
    variable mem : word_array_t(0 to length - 1) := (others => (others => '0'));
    variable l   : line;
    variable idx : integer := 0;
    variable value : std_logic_vector(31 downto 0);
  begin
    if length = 0 then
      return mem;
    end if;
    if file_name'length = 0 then
      return mem;
    end if;
    file_open(status, f, file_name, read_mode);
    if status /= open_ok then
      if STRICT_FILES then
        report "load_words: failed to open '" & file_name & "' (" &
               file_open_status'image(status) & ")"
          severity failure;
      else
        report "load_words: failed to open '" & file_name & "' (" &
               file_open_status'image(status) & "); using zeros"
          severity warning;
      end if;
      return mem;
    end if;
    while not endfile(f) loop
      exit when idx >= length;
      readline(f, l);
      if l'length = 0 then
        next;
      end if;
      hread(l, value);
      mem(idx) := value;
      idx := idx + 1;
    end loop;
    file_close(f);
    return mem;
  end function;

  -- Clock and reset.
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  -- Core memory-bus signals snooped from top_trace for signature tracking.
  signal write_data : word_t := (others => '0');
  signal data_adr   : word_t := (others => '0');
  signal mem_write  : std_logic := '0';
  signal mem_wstrb  : std_logic_vector(3 downto 0) := (others => '0');

  -- Debug/trace ports exposed by top_trace (directly from controller/datapath).
  signal pc_dbg     : word_t := (others => '0');
  signal instr_dbg  : word_t := (others => '0');
  signal result_src_dbg  : ResultSrc_t;
  signal mem_write_dbg   : std_logic;
  signal mem_read_dbg    : std_logic;
  signal pc_src_dbg      : std_logic;
  signal alu_src_dbg     : std_logic;
  signal reg_write_dbg   : std_logic;
  signal jump_dbg        : std_logic;
  signal jalr_dbg        : std_logic;
  signal imm_src_dbg     : ImmSrc_t;
  signal alu_control_dbg : ALUControl_t;
  signal mem_size_dbg    : std_logic_vector(1 downto 0);
  signal mem_unsigned_dbg: std_logic;
  signal branch_op_dbg   : BranchOp_t;
  signal src_a_sel_dbg   : SrcASel_t;
  signal branch_taken_dbg: std_logic;

  -- Hazard-unit debug outputs (forwarding selects and stall/flush decisions).
  signal stall_f_dbg     : std_logic := '0';
  signal stall_d_dbg     : std_logic := '0';
  signal flush_d_dbg     : std_logic := '0';
  signal flush_e_dbg     : std_logic := '0';
  signal forward_a_dbg   : std_logic_vector(1 downto 0) := "00";
  signal forward_b_dbg   : std_logic_vector(1 downto 0) := "00";

  -- Per-stage instruction word tracking (identifies which instruction is
  -- in each pipeline stage for the trace annotation).
  signal instr_d_dbg     : word_t := (others => '0');
  signal instr_e_dbg     : word_t := (others => '0');
  signal instr_m_dbg     : word_t := (others => '0');
  signal instr_w_dbg     : word_t := (others => '0');

  -- Cycle counter (reset-relative); used for trace output and timeout.
  signal cycle_count     : natural := 0;

  -- Testbench-local shadow copy of the DMEM contents.  The actual dmem entity
  -- is a black-box from the testbench's perspective (no extra read port), so
  -- dmem_write_proc mirrors every CPU store here, byte-lane by byte-lane.
  -- This gives completion_proc and timeout_proc direct read access to check
  -- the signature region against expected values without touching the RTL DMEM.
  -- Initialized from the same hex file the RTL DMEM uses so pre-initialized
  -- .data values are already present before the first instruction executes.
  signal dmem_storage : word_array_t(0 to DMEM_WORDS - 1) := load_words(DMEM_INIT_FILE, DMEM_WORDS);

  -- Golden signature loaded from the .sig file; compared word-by-word against
  -- the corresponding dmem_storage entries to decide pass/fail.
  signal expected_sig : word_array_t(0 to SIGNATURE_WORDS - 1) := load_words(EXPECTED_FILE, SIGNATURE_WORDS);

  -- Word index into dmem_storage where the signature window starts.
  constant SIGNATURE_INDEX : integer := (SIGNATURE_ADDR - DMEM_BASE_INT) / 4;
  -- Upper bound of DMEM address space (byte offset from DMEM_BASE).
  constant DMEM_TOP : unsigned(31 downto 0) := to_unsigned(DMEM_WORDS * 4, 32);
  -- First byte address past the signature window (used for sanity checks).
  constant SIGNATURE_END  : unsigned(31 downto 0) := to_unsigned(SIGNATURE_ADDR + (SIGNATURE_WORDS * 4), 32);

  -- Compares the DMEM signature window against the EXPECTED_FILE contents.
  impure function signature_matches return boolean is
    variable match : boolean := true;
  begin
    for i in 0 to SIGNATURE_WORDS - 1 loop
      if dmem_storage(SIGNATURE_INDEX + i) /= expected_sig(i) then
        match := false;
        exit;
      end if;
    end loop;
    return match;
  end function;

  -- ========================================================================
  -- Immediate extraction helpers (trace disassembly)
  --
  -- Each function replicates the RV32I immediate decode for one format,
  -- sign-extending to 32 bits and returning a plain integer for easy
  -- printing by write_asm().
  -- ========================================================================

  -- I-type immediate: instr[31:20], sign-extended.
  function imm_i(instr : word_t) return integer is
    variable imm : signed(31 downto 0);
  begin
    imm := resize(signed(instr(31 downto 20)), 32);
    return to_integer(imm);
  end function;

  -- S-type immediate: {instr[31:25], instr[11:7]}, sign-extended.
  function imm_s(instr : word_t) return integer is
    variable imm : signed(31 downto 0);
    variable raw : std_logic_vector(11 downto 0);
  begin
    raw := instr(31 downto 25) & instr(11 downto 7);
    imm := resize(signed(raw), 32);
    return to_integer(imm);
  end function;

  -- B-type immediate: {instr[31], instr[7], instr[30:25], instr[11:8], 1'b0},
  -- sign-extended (always even, encodes a PC-relative byte offset).
  function imm_b(instr : word_t) return integer is
    variable imm : signed(31 downto 0);
    variable raw : std_logic_vector(12 downto 0);
  begin
    raw := instr(31) & instr(7) & instr(30 downto 25) & instr(11 downto 8) & '0';
    imm := resize(signed(raw), 32);
    return to_integer(imm);
  end function;

  -- J-type immediate: {instr[31], instr[19:12], instr[20], instr[30:21], 1'b0},
  -- sign-extended (always even, encodes a PC-relative byte offset).
  function imm_j(instr : word_t) return integer is
    variable imm : signed(31 downto 0);
    variable raw : std_logic_vector(20 downto 0);
  begin
    raw := instr(31) & instr(19 downto 12) & instr(20) & instr(30 downto 21) & '0';
    imm := resize(signed(raw), 32);
    return to_integer(imm);
  end function;

  -- U-type immediate: instr[31:12] placed in bits [31:12], lower 12 bits zero.
  -- Returns a full 32-bit word so the trace can print it in hex.
  function imm_u_hex(instr : word_t) return word_t is
    variable imm : word_t := (others => '0');
  begin
    imm(31 downto 12) := instr(31 downto 12);
    return imm;
  end function;

  -- Append "xN" (e.g. "x0", "x31") to a text line for register names.
  procedure write_reg(l : inout line; regnum : integer) is
  begin
    write(l, string'("x"));
    write(l, regnum);
  end procedure;

  -- Disassemble a 32-bit RV32I instruction word into human-readable assembly
  -- text (e.g. "addi x1, x0, 5") and append it to the line buffer. Covers
  -- the full supported instruction subset: LUI, AUIPC, JAL, JALR, branches,
  -- loads, stores, OP-IMM, and OP.  Unknown opcodes print "unknown".
  procedure write_asm(l : inout line; instr : word_t) is
    variable opcode : std_logic_vector(6 downto 0);
    variable funct3 : std_logic_vector(2 downto 0);
    variable funct7b5 : std_logic;
    variable rd  : integer;
    variable rs1 : integer;
    variable rs2 : integer;
    variable shamt : integer;
  begin
    opcode := instr(6 downto 0);
    funct3 := instr(14 downto 12);
    funct7b5 := instr(30);
    rd  := to_integer(unsigned(instr(11 downto 7)));
    rs1 := to_integer(unsigned(instr(19 downto 15)));
    rs2 := to_integer(unsigned(instr(24 downto 20)));
    shamt := to_integer(unsigned(instr(24 downto 20)));

    case opcode is
      when "0110111" =>  -- LUI
        write(l, string'("lui "));
        write_reg(l, rd);
        write(l, string'(", 0x"));
        write(l, to_hstring(imm_u_hex(instr)));
      when "0010111" =>  -- AUIPC
        write(l, string'("auipc "));
        write_reg(l, rd);
        write(l, string'(", 0x"));
        write(l, to_hstring(imm_u_hex(instr)));
      when "1101111" =>  -- JAL
        write(l, string'("jal "));
        write_reg(l, rd);
        write(l, string'(", "));
        write(l, imm_j(instr));
      when "1100111" =>  -- JALR
        write(l, string'("jalr "));
        write_reg(l, rd);
        write(l, string'(", "));
        write(l, imm_i(instr));
        write(l, string'("("));
        write_reg(l, rs1);
        write(l, string'(")"));
      when "1100011" =>  -- Branches
        case funct3 is
          when "000" => write(l, string'("beq "));
          when "001" => write(l, string'("bne "));
          when "100" => write(l, string'("blt "));
          when "101" => write(l, string'("bge "));
          when "110" => write(l, string'("bltu "));
          when "111" => write(l, string'("bgeu "));
          when others => write(l, string'("b? "));
        end case;
        write_reg(l, rs1);
        write(l, string'(", "));
        write_reg(l, rs2);
        write(l, string'(", "));
        write(l, imm_b(instr));
      when "0000011" =>  -- Loads
        case funct3 is
          when "000" => write(l, string'("lb "));
          when "001" => write(l, string'("lh "));
          when "010" => write(l, string'("lw "));
          when "100" => write(l, string'("lbu "));
          when "101" => write(l, string'("lhu "));
          when others => write(l, string'("l? "));
        end case;
        write_reg(l, rd);
        write(l, string'(", "));
        write(l, imm_i(instr));
        write(l, string'("("));
        write_reg(l, rs1);
        write(l, string'(")"));
      when "0100011" =>  -- Stores
        case funct3 is
          when "000" => write(l, string'("sb "));
          when "001" => write(l, string'("sh "));
          when others => write(l, string'("sw "));
        end case;
        write_reg(l, rs2);
        write(l, string'(", "));
        write(l, imm_s(instr));
        write(l, string'("("));
        write_reg(l, rs1);
        write(l, string'(")"));
      when "0010011" =>  -- OP-IMM
        case funct3 is
          when "000" => write(l, string'("addi "));
          when "010" => write(l, string'("slti "));
          when "011" => write(l, string'("sltiu "));
          when "100" => write(l, string'("xori "));
          when "110" => write(l, string'("ori "));
          when "111" => write(l, string'("andi "));
          when "001" => write(l, string'("slli "));
          when "101" =>
            if funct7b5 = '1' then
              write(l, string'("srai "));
            else
              write(l, string'("srli "));
            end if;
          when others => write(l, string'("opimm "));
        end case;
        write_reg(l, rd);
        write(l, string'(", "));
        write_reg(l, rs1);
        write(l, string'(", "));
        if funct3 = "001" or funct3 = "101" then
          write(l, shamt);
        else
          write(l, imm_i(instr));
        end if;
      when "0110011" =>  -- OP
        case funct3 is
          when "000" =>
            if funct7b5 = '1' then
              write(l, string'("sub "));
            else
              write(l, string'("add "));
            end if;
          when "001" => write(l, string'("sll "));
          when "010" => write(l, string'("slt "));
          when "011" => write(l, string'("sltu "));
          when "100" => write(l, string'("xor "));
          when "101" =>
            if funct7b5 = '1' then
              write(l, string'("sra "));
            else
              write(l, string'("srl "));
            end if;
          when "110" => write(l, string'("or "));
          when "111" => write(l, string'("and "));
          when others => write(l, string'("op "));
        end case;
        write_reg(l, rd);
        write(l, string'(", "));
        write_reg(l, rs1);
        write(l, string'(", "));
        write_reg(l, rs2);
      when others =>
        write(l, string'("unknown"));
    end case;
  end procedure;

  -- ========================================================================
  -- Enum/signal-to-string helpers (trace formatting)
  --
  -- Each function converts an RTL control signal or enum value into a short
  -- human-readable string for the per-instruction trace output.
  -- ========================================================================

  -- Map a std_logic to one of two names (e.g. '1' -> "stall", '0' -> "run").
  function sl_name(sig : std_logic; high_name : string; low_name : string) return string is
  begin
    if sig = '1' then
      return high_name;
    end if;
    return low_name;
  end function;

  -- Writeback mux source: "alu", "mem", or "pc+4".
  function result_src_name(sel : ResultSrc_t) return string is
  begin
    case sel is
      when WB_ALU => return "alu";
      when WB_MEM => return "mem";
      when WB_PC4 => return "pc+4";
    end case;
  end function;

  -- ALU operation name (e.g. "add", "sub", "sll", etc.).
  function alu_control_name(sel : ALUControl_t) return string is
  begin
    case sel is
      when ALU_ADD  => return "add";
      when ALU_SUB  => return "sub";
      when ALU_AND  => return "and";
      when ALU_OR   => return "or";
      when ALU_XOR  => return "xor";
      when ALU_SLT  => return "slt";
      when ALU_SLTU => return "sltu";
      when ALU_SLL  => return "sll";
      when ALU_SRL  => return "srl";
      when ALU_SRA  => return "sra";
    end case;
  end function;

  -- Immediate format letter ("I", "S", "B", "U", "J").
  function imm_src_name(sel : ImmSrc_t) return string is
  begin
    case sel is
      when IMM_I => return "I";
      when IMM_S => return "S";
      when IMM_B => return "B";
      when IMM_U => return "U";
      when IMM_J => return "J";
    end case;
  end function;

  -- Branch comparator mode ("none", "eq", "ne", "lt", "ge", "ltu", "geu").
  function branch_op_name(sel : BranchOp_t) return string is
  begin
    case sel is
      when BR_NONE => return "none";
      when BR_EQ   => return "eq";
      when BR_NE   => return "ne";
      when BR_LT   => return "lt";
      when BR_GE   => return "ge";
      when BR_LTU  => return "ltu";
      when BR_GEU  => return "geu";
    end case;
  end function;

  -- ALU A-input source ("rs1", "pc", "zero").
  function src_a_name(sel : SrcASel_t) return string is
  begin
    case sel is
      when OPA_RS1  => return "rs1";
      when OPA_PC   => return "pc";
      when OPA_ZERO => return "zero";
    end case;
  end function;

  -- Memory access width ("byte", "half", "word").
  function mem_size_name(sel : std_logic_vector(1 downto 0)) return string is
  begin
    case sel is
      when MEM_BYTE => return "byte";
      when MEM_HALF => return "half";
      when others   => return "word";
    end case;
  end function;

  -- Jump type: "jal", "jalr", or "no".
  function jump_name(jump : std_logic; jalr : std_logic) return string is
  begin
    if jump = '1' then
      if jalr = '1' then
        return "jalr";
      end if;
      return "jal";
    end if;
    return "no";
  end function;

  -- Forwarding source for the E-stage operand: "rf" (register file, no
  -- forwarding), "M" (from Memory stage), "W" (from Writeback stage).
  function forward_sel_name(sel : std_logic_vector(1 downto 0)) return string is
  begin
    case sel is
      when "00" => return "rf";
      when "10" => return "M";
      when "01" => return "W";
      when others => return "??";
    end case;
  end function;

  -- Append " key=val" to a trace line (unconditional).
  procedure write_kv(l : inout line; key : string; val : string) is
  begin
    write(l, string'(" "));
    write(l, key);
    write(l, string'("="));
    write(l, val);
  end procedure;

  -- Append " key=val" to a trace line only when cond is true.
  -- Used to suppress default/inactive control signals from the trace.
  procedure write_kv_if(
    l    : inout line;
    cond : boolean;
    key  : string;
    val  : string
  ) is
  begin
    if cond then
      write_kv(l, key, val);
    end if;
  end procedure;

  -- Print a TRACE: TotalCycles=N line (used by completion_proc and
  -- timeout_proc).  Guarded by TRACE_ENABLE so callers stay concise.
  procedure write_cycle_count(count : natural) is
    variable blank : line;
    variable l     : line;
  begin
    if TRACE_ENABLE then
      writeline(output, blank);
      write(l, string'("TRACE: TotalCycles="));
      write(l, count);
      writeline(output, l);
    end if;
  end procedure;

  -- Write a stage annotation " [instruction]" to the trace line. Flushed
  -- pipeline slots (all-zero instruction word) are shown as "---".
  procedure write_stage_instr(l : inout line; instr : word_t) is
  begin
    write(l, string'(" ["));
    if instr = x"00000000" then
      write(l, string'("---"));
    else
      write_asm(l, instr);
    end if;
    write(l, string'("]"));
  end procedure;

begin
  -- Sanity checks to catch mis-configured testbench parameters quickly.
  assert SIGNATURE_WORDS > 0 report "SIGNATURE_WORDS must be > 0" severity failure;
  assert SIGNATURE_INDEX >= 0 report "SIGNATURE address before DMEM" severity failure;
  assert SIGNATURE_END <= DMEM_BASE + DMEM_TOP
    report "Signature window exceeds DMEM size" severity failure;

  -- Free-running clock with 50% duty cycle.
  clk_process : process
  begin
    while true loop
      clk <= '0';
      wait for CLK_PERIOD / 2;
      clk <= '1';
      wait for CLK_PERIOD / 2;
    end loop;
  end process;

  -- Range monitor: only flag invalid DMEM addresses when an actual store is
  -- requested. This avoids false triggers when unrelated instructions drive
  -- the ALU result outside the DMEM window.
  access_monitor : process(clk)
    variable addr_u : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if mem_write = '1' then
        if not addr_valid(data_adr) then
          report "Data write address contains X/U/Z: " & to_hstring(data_adr) severity failure;
        else
          addr_u := unsigned(data_adr);
          if addr_u < DMEM_BASE then
            report "Attempted write to read-only region: " & to_hstring(data_adr) severity failure;
          else
            addr_u := addr_u - DMEM_BASE;
            if addr_u >= DMEM_TOP then
              report "Data write address out of range: " & to_hstring(data_adr) severity failure;
            end if;
          end if;
        end if;
      end if;
    end if;
  end process;

  -- Apply reset for a few cycles at startup.
  reset_process : process
  begin
    rst <= '1';
    wait for 5 * CLK_PERIOD;
    rst <= '0';
    wait;
  end process;

  cycle_count_proc : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        cycle_count <= 0;
      else
        cycle_count <= cycle_count + 1;
      end if;
    end if;
  end process;

  top_inst : entity work.top_trace
    generic map (
      IMEM_WORDS     => IMEM_WORDS,
      DMEM_WORDS     => DMEM_WORDS,
      IMEM_INIT_FILE => IMEM_INIT_FILE,
      DMEM_INIT_FILE => DMEM_INIT_FILE,
      FORWARDING_ENABLE => FORWARDING_ENABLE
    )
    port map (
      clk              => clk,
      reset            => rst,
      WriteData        => write_data,
      DataAdr          => data_adr,
      MemWrite         => mem_write,
      MemRead          => open,
      MemWStrb         => mem_wstrb,
      PCDbg            => pc_dbg,
      InstrDbg         => instr_dbg,
      result_src_dbg   => result_src_dbg,
      mem_write_dbg    => mem_write_dbg,
      mem_read_dbg     => mem_read_dbg,
      pc_src_dbg       => pc_src_dbg,
      alu_src_dbg      => alu_src_dbg,
      reg_write_dbg    => reg_write_dbg,
      jump_dbg         => jump_dbg,
      jalr_dbg         => jalr_dbg,
      imm_src_dbg      => imm_src_dbg,
      alu_control_dbg  => alu_control_dbg,
      mem_size_dbg     => mem_size_dbg,
      mem_unsigned_dbg => mem_unsigned_dbg,
      branch_op_dbg    => branch_op_dbg,
      src_a_sel_dbg    => src_a_sel_dbg,
      branch_taken_dbg => branch_taken_dbg,
      stall_f_dbg      => stall_f_dbg,
      stall_d_dbg      => stall_d_dbg,
      flush_d_dbg      => flush_d_dbg,
      flush_e_dbg      => flush_e_dbg,
      forward_a_dbg    => forward_a_dbg,
      forward_b_dbg    => forward_b_dbg,
      instr_d_dbg      => instr_d_dbg,
      instr_e_dbg      => instr_e_dbg,
      instr_m_dbg      => instr_m_dbg,
      instr_w_dbg      => instr_w_dbg
    );

  -- Mirror writes into a local DMEM view so signature checks can see the
  -- full post-store word contents.  Address validation (X/U/Z and range)
  -- is handled by access_monitor above; this process only updates the
  -- shadow array for in-range stores.
  dmem_write_proc : process(clk)
    variable idx : integer;
    variable current : word_t;
    variable addr_u : unsigned(31 downto 0);
    variable offset : unsigned(31 downto 0);
  begin
    if rising_edge(clk) then
      if mem_write = '1' and addr_valid(data_adr) then
        addr_u := unsigned(data_adr);
        if addr_u >= DMEM_BASE and (addr_u - DMEM_BASE) < DMEM_TOP then
          offset := addr_u - DMEM_BASE;
          idx := to_integer(unsigned(offset(31 downto 2)));
          current := dmem_storage(idx);
          for b in 0 to 3 loop
            if mem_wstrb(b) = '1' then
              current((b * 8) + 7 downto b * 8) := write_data((b * 8) + 7 downto b * 8);
            end if;
          end loop;
          dmem_storage(idx) <= current;
        end if;
      end if;
    end if;
  end process;

  -- Completion monitor: waits for reset release, then checks whether the
  -- signature window matches the expected contents.
  completion_proc : process
    variable done : boolean := false;
  begin
    wait until rst = '0';
    while not done loop
      wait until rising_edge(clk);
      if signature_matches then
        write_cycle_count(cycle_count);
        report "TEST PASSED" severity note;
        done := true;
        if HALT_ON_PASS then
          stop(0);
        end if;
      end if;
    end loop;
    wait;
  end process;

  -- Timeout monitor: after MAX_CYCLES, fail if the signature was not fully
  -- written by the program.
  timeout_proc : process
  begin
    -- Count cycles *after* reset deassertion (matches completion_proc).
    wait until rst = '0';
    wait for CLK_PERIOD * MAX_CYCLES;
    write_cycle_count(cycle_count);
    for i in 0 to SIGNATURE_WORDS - 1 loop
      assert dmem_storage(SIGNATURE_INDEX + i) = expected_sig(i)
        report "Signature mismatch at index "
               & integer'image(i)
               & " expected "
               & to_hstring(expected_sig(i))
               & " got "
               & to_hstring(dmem_storage(SIGNATURE_INDEX + i))
        severity failure;
    end loop;
    assert false report "Signature not reached before MAX_CYCLES" severity failure;
  end process;

  -- Per-instruction trace printer. On every rising clock edge (when
  -- TRACE_ENABLE=true and reset is released), prints a multi-line block:
  --   ASM=<disassembled instruction>
  --   FETCH:  PC and raw instruction word
  --   DECODE: immediate format, branch op, jump type (if active)
  --   EXEC:   ALU-A source, ALU-B source, ALU op, branch/PCSrc (if taken)
  --   MEM:    read/write enables, access size, unsigned flag (if active)
  --   WB:     result source mux, register write enable
  --   HAZARD: stall/flush/forward decisions (only when non-default)
  trace_proc : process(clk)
    variable l_asm   : line;
    variable l_fetch : line;
    variable l_dec   : line;
    variable l_exe   : line;
    variable l_mem   : line;
    variable l_wb    : line;
    variable l_haz   : line;
    variable blank   : line;
  begin
    if rising_edge(clk) then
      if rst = '0' and TRACE_ENABLE then
        writeline(output, blank);
        write(l_asm, string'("ASM="));
        write_asm(l_asm, instr_dbg);
        writeline(output, l_asm);

        write(l_fetch, string'("FETCH: PC=0x"));
        write(l_fetch, to_hstring(pc_dbg));
        write(l_fetch, string'(" INSTR=0x"));
        write(l_fetch, to_hstring(instr_dbg));
        writeline(output, l_fetch);

        write(l_dec, string'("DECODE"));
        write_stage_instr(l_dec, instr_d_dbg);
        write(l_dec, string'(": ImmSrc="));
        write(l_dec, imm_src_name(imm_src_dbg));
        write_kv_if(l_dec, branch_op_dbg /= BR_NONE, "BranchOp", branch_op_name(branch_op_dbg));
        write_kv_if(l_dec, jump_dbg = '1', "Jump", jump_name(jump_dbg, jalr_dbg));
        writeline(output, l_dec);

        write(l_exe, string'("EXEC"));
        write_stage_instr(l_exe, instr_e_dbg);
        write(l_exe, string'(": SrcA="));
        write(l_exe, src_a_name(src_a_sel_dbg));
        write_kv(l_exe, "ALUSrc", sl_name(alu_src_dbg, "imm", "rs2"));
        write_kv(l_exe, "ALUControl", alu_control_name(alu_control_dbg));
        write_kv_if(l_exe, branch_taken_dbg = '1', "Zero", "taken");
        write_kv_if(l_exe, pc_src_dbg = '1', "PCSrc", "target");
        writeline(output, l_exe);

        write(l_mem, string'("MEM"));
        write_stage_instr(l_mem, instr_m_dbg);
        write(l_mem, string'(":"));
        write_kv_if(l_mem, mem_read_dbg = '1', "MemRead", "yes");
        write_kv_if(l_mem, mem_write_dbg = '1', "MemWrite", "yes");
        write_kv_if(l_mem, (mem_read_dbg = '1') or (mem_write_dbg = '1'),
                    "MemSize", mem_size_name(mem_size_dbg));
        write_kv_if(l_mem, mem_unsigned_dbg = '1', "MemUnsigned", "unsigned");
        writeline(output, l_mem);

        write(l_wb, string'("WB"));
        write_stage_instr(l_wb, instr_w_dbg);
        write(l_wb, string'(": ResultSrc="));
        write(l_wb, result_src_name(result_src_dbg));
        write_kv_if(l_wb, reg_write_dbg = '1', "RegWrite", "yes");
        writeline(output, l_wb);

        if (stall_f_dbg = '1') or (stall_d_dbg = '1') or (flush_d_dbg = '1') or (flush_e_dbg = '1') or
           (forward_a_dbg /= "00") or (forward_b_dbg /= "00") then
          write(l_haz, string'("HAZARD"));
          write_stage_instr(l_haz, instr_e_dbg);
          write(l_haz, string'(":"));
          write_kv(l_haz, "StallF", sl_name(stall_f_dbg, "stall", "run"));
          write_kv(l_haz, "StallD", sl_name(stall_d_dbg, "stall", "run"));
          write_kv(l_haz, "FlushD", sl_name(flush_d_dbg, "flush", "keep"));
          write_kv(l_haz, "FlushE", sl_name(flush_e_dbg, "flush", "keep"));
          write_kv(l_haz, "FwdA", forward_sel_name(forward_a_dbg));
          write_kv(l_haz, "FwdB", forward_sel_name(forward_b_dbg));
          writeline(output, l_haz);
        end if;
      end if;
    end if;
  end process;

end architecture sim;
