.PHONY: all pdf clean tidy

TEX := main.tex

all:
	@command -v latexmk >/dev/null 2>&1 || { \
		echo "error: latexmk not found. Install TeX Live + latexmk (see latex/README.md)."; \
		exit 1; \
	}
	latexmk -pdf -interaction=nonstopmode -halt-on-error $(TEX)

# Build the PDF, then remove every auxiliary file (including .bbl), leaving
# only main.pdf.
pdf:
	@command -v latexmk >/dev/null 2>&1 || { \
		echo "error: latexmk not found. Install TeX Live + latexmk (see latex/README.md)."; \
		exit 1; \
	}
	latexmk -pdf -interaction=nonstopmode -halt-on-error $(TEX)
	latexmk -c -bibtex $(TEX)

clean:
	@command -v latexmk >/dev/null 2>&1 || { \
		echo "error: latexmk not found. Install TeX Live + latexmk (see latex/README.md)."; \
		exit 1; \
	}
	latexmk -C $(TEX)

tidy:
	@command -v latexmk >/dev/null 2>&1 || { \
		echo "error: latexmk not found. Install TeX Live + latexmk (see latex/README.md)."; \
		exit 1; \
	}
	latexmk -c $(TEX)
