LATEXMK := latexmk

.PHONY: all manual pdf tidy clean check

all: manual

manual: check
	$(MAKE) -C manual

# Build the manual PDF, then strip every auxiliary file so only main.pdf remains.
pdf: check
	$(MAKE) -C manual pdf

# Remove intermediate aux files but keep the built PDF.
tidy: check
	-$(MAKE) -C manual tidy

clean: check
	-$(MAKE) -C manual clean
	rm -rf build

check:
	@command -v $(LATEXMK) >/dev/null 2>&1 || { \
	  echo "error: '$(LATEXMK)' not found. Install TeX Live and latexmk (see docs/prerequisites.md)."; \
	  exit 1; }
