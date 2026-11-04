// The JS lane runs one core with no raw terminal: it never has input.
function tty_getc() {
  return 0xFFFFFFFF;
}

io_eff(CID(Tty.getc), tty_getc);
