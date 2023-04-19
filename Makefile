.PHONY: all test clean doc build examples

all:	octant

octant:
	dune build src/cli/octant.exe
	ln -fs _build/default/src/cli/*.exe .

test:
	dune build test/testparse.exe test/testparseformula.exe test/testarrays.exe test/testtfg.exe test/testprojection.exe
	ln -fs _build/default/test/*.exe .

clean:
	find -L . -name "*~" -delete
	rm -f *.exe *.native
	dune clean

