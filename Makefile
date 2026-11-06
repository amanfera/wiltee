# wiltee: a RISC-V machine as a pure Bend function.
BEND ?= bend
CC_RV ?= $(shell command -v clang-19 || command -v clang)
LD_RV ?= $(shell command -v ld.lld-19 || command -v ld.lld)
OBJCOPY_RV ?= $(shell command -v llvm-objcopy-19 || command -v llvm-objcopy)
RVFLAGS = --target=riscv32 -march=rv32ima -mabi=ilp32 -nostdlib
LINUX = build/linux/Image platform/wiltee.dtb build/linux/rootfs.cpio

.PHONY: all check check64 test test-bare test-bare64 test-rvc test-isa test-isa64 test-linux linux run clean

# RVC: C.expand against LLVM and the spec for all 49,152 halfwords
test-rvc:
	tests/rvc/check.sh

all: build/wiltee build/fleet platform/wiltee.dtb build/wiltee64 build/fleet64 build/cow64 platform/wiltee64.dtb platform/wiltee64-sh.dtb

# bend exits non-zero when a file depends on @unsafe/foreign code (the host
# loops do), so success is judged by the binary it leaves behind.
build/wiltee: src/hart.bend src/wiltee.bend src/tty.c src/tty.js
	@mkdir -p build
	-@$(BEND) src/wiltee.bend -o $@ > build/wiltee.log 2>&1
	@test -x $@ || (cat build/wiltee.log; exit 1)

build/wiltee64: src/hart64.bend src/rvc.bend src/wiltee64.bend src/tty.c src/tty.js
	@mkdir -p build
	-@$(BEND) src/wiltee64.bend -o $@ > build/wiltee64.log 2>&1
	@test -x $@ || (cat build/wiltee64.log; exit 1)

build/fleet: src/hart.bend src/fleet.bend
	@mkdir -p build
	-@$(BEND) src/fleet.bend -o $@ > build/fleet.log 2>&1
	@test -x $@ || (cat build/fleet.log; exit 1)

platform/%.dtb: platform/%.dts
	dtc -q -I dts -O dtb -o $@ $<

# RV64 device trees for N harts: platform/wiltee64-smpN.dts
platform/wiltee64-smp%.dts: scripts/mkdts64.py
	python3 scripts/mkdts64.py --harts $* > $@

build/cow64: src/hart64.bend src/rvc.bend src/cow64.bend
	@mkdir -p build
	-@$(BEND) src/cow64.bend -o $@ > build/cow64.log 2>&1
	@test -x $@ || (cat build/cow64.log; exit 1)

build/fleet64: src/hart64.bend src/rvc.bend src/fleet64.bend
	@mkdir -p build
	-@$(BEND) src/fleet64.bend -o $@ > build/fleet64.log 2>&1
	@test -x $@ || (cat build/fleet64.log; exit 1)

# RV64 bare-metal images (with C)
build/%64.bin: tests/bare/%64.S
	@mkdir -p build
	$(CC_RV) --target=riscv64 -march=rv64imac -mabi=lp64 -nostdlib -c $< -o build/$*64.o
	$(LD_RV) -Ttext=0 -o build/$*64.elf build/$*64.o
	$(OBJCOPY_RV) -O binary build/$*64.elf $@

build/%.bin: tests/bare/%.S
	@mkdir -p build
	$(CC_RV) $(RVFLAGS) -c $< -o build/$*.o
	$(LD_RV) -Ttext=0 -o build/$*.elf build/$*.o
	$(OBJCOPY_RV) -O binary build/$*.elf $@

# The machine (src/hart.bend) has no @unsafe: the checker proves every
# epoch halts.
check:
	$(BEND) src/hart.bend

# The same for the RV64 machine.
check64:
	$(BEND) src/hart64.bend

test-bare: build/wiltee build/fleet build/hello.bin build/fleet.bin
	./build/wiltee build/hello.bin - - | grep -q '^PASS'
	./build/fleet build/fleet.bin 2 | grep -q 'vm 00000003 f1667903'
	@echo "bare tests: PASS"

# 4 RV64 machines, one bang for the whole run; results checked against the
# LCG computed by tests/bare/fleet64.py.
test-bare64: build/fleet64 build/fleet64.bin
	./build/fleet64 build/fleet64.bin 2 run | grep '^vm' | cut -c1-36 > build/fleet64.out
	python3 tests/bare/fleet64.py 4 | diff - build/fleet64.out
	@echo "bare64 tests: PASS"

test-isa: build/wiltee
	scripts/isa-tests.sh

test-isa64: build/wiltee64
	XLEN=64 scripts/isa-tests.sh

linux: build/linux/Image

build/linux/Image:
	scripts/fetch-linux.sh

test-linux: build/wiltee platform/wiltee.dtb build/linux/Image
	tests/interactive.py

test: check test-bare test-isa test-linux

run: build/wiltee platform/wiltee.dtb build/linux/Image
	./build/wiltee $(LINUX)

clean:
	rm -rf build
