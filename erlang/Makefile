# SPDX-License-Identifier: MIT
# Copyright (C) 2026 Ahmad Parr

# twinpay build
ERLC = erlc
EBIN = ebin
PRIV = priv

all: $(EBIN) $(PRIV)/worm_port compile app_file

$(EBIN):
	mkdir -p $(EBIN)

# The vendored worm_commit.c uses POSIX lseek/write/fsync without including
# the headers. -include injects the declarations without modifying the
# verbatim vendored file. USE_OPENSSL selects real SHA-256 chaining.
$(PRIV)/worm_port: c_src/worm_port.c c_src/worm_commit.c c_src/worm_block.h
	gcc -O2 -Wall -DUSE_OPENSSL \
		-include unistd.h -include fcntl.h -include sys/types.h \
		-o $(PRIV)/worm_port c_src/worm_port.c c_src/worm_commit.c -lcrypto

compile:
	$(ERLC) -o $(EBIN) -Wall src/*.erl

app_file:
	cp src/twinpay.app.src $(EBIN)/twinpay.app

test: all
	$(ERLC) -o $(EBIN) -Wall test/*.erl
	erl -noshell -pa $(EBIN) -eval 'twinpay_tests:run().'

clean:
	rm -rf $(EBIN) $(PRIV)/worm_port $(PRIV)/worm.dat

.PHONY: all compile app_file test clean
