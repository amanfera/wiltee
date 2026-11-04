// Tty.getc: one byte from stdin without waiting. On a terminal it switches to
// raw mode once (restored at exit), so line editing, echo and Ctrl-C belong
// to the guest; Ctrl-A x asks the emulator to quit.
#include <poll.h>
#include <termios.h>
#include <unistd.h>

static struct termios tty_saved;
static int tty_mode = 0; // 0 unset, 1 raw terminal, 2 not a terminal
static int tty_esc = 0;

static void tty_restore(void) {
  if (tty_mode == 1) tcsetattr(0, TCSANOW, &tty_saved);
}

static void tty_setup(void) {
  if (tty_mode) return;
  tty_mode = 2;
  if (!isatty(0) || tcgetattr(0, &tty_saved) != 0) return;
  struct termios t = tty_saved;
  t.c_lflag &= ~(ICANON | ECHO | ISIG | IEXTEN);
  t.c_iflag &= ~(IXON | ICRNL);
  t.c_cc[VMIN] = 1;
  t.c_cc[VTIME] = 0;
  if (tcsetattr(0, TCSANOW, &t) == 0) {
    tty_mode = 1;
    atexit(tty_restore);
  }
}

Term tty_getc_run(Env e, Term* f, IoWork* w) {
  tty_setup();
  struct pollfd p = { 0, POLLIN, 0 };
  if (poll(&p, 1, 0) <= 0) return (Term)(u32)0xFFFFFFFFu;
  unsigned char c;
  ssize_t r = read(0, &c, 1);
  if (r == 0) return (Term)(u32)0xFFFFFFFEu;
  if (r < 0) return (Term)(u32)0xFFFFFFFFu;
  if (tty_esc) {
    tty_esc = 0;
    if (c == 'x') return (Term)(u32)0xFFFFFFFDu;
  } else if (c == 1 && tty_mode == 1) {
    tty_esc = 1;
    return (Term)(u32)0xFFFFFFFFu;
  }
  return (Term)(u32)c;
}

static void __attribute__((constructor)) tty_getc_use(void) {
  io_eff(CID(Tty.getc), tty_getc_run);
}
