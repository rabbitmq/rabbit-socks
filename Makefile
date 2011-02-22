PACKAGE=rabbit_socks
APPNAME=rabbit_socks
DEPS=rabbitmq-server rabbitmq-erlang-client rabbitmq-mochiweb

EXTRA_PACKAGE_DIRS=priv

START_RABBIT_IN_TESTS=true
TEST_APPS=inets rabbit_mochiweb rabbit_socks
TEST_SCRIPTS=./test/test.py
UNIT_TEST_COMMANDS=eunit:test(rabbit_socks_test_util,[verbose])

# TEST_ARGS=-rabbit_stomp listeners "[{\"0.0.0.0\",61613}]"

include ../include.mk

test: unittest

unittest: $(TARGETS) $(TEST_TARGETS)
	ERL_LIBS=$(LIBS_PATH) $(ERL) $(TEST_LOAD_PATH) \
		$(foreach CMD,$(UNIT_TEST_COMMANDS),-eval '$(CMD)') \
		-eval 'init:stop()' | tee $(TMPDIR)/rabbit-socks-unittest-output |\
			egrep "passed" >/dev/null
