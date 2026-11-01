ldc2 -unittest -i -Isrc src/ve/*.d -of=ve-test || exit 1
rm ve-test.o
./ve-test
