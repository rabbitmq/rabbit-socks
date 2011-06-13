APP_NAME:=rabbit_socks
DEPS:=rabbitmq-server rabbitmq-erlang-client rabbitmq-mochiweb

WITH_BROKER_TEST_COMMANDS=eunit:test(rabbit_socks_test_util,[verbose])

define construct_app_commands
	cp -r $(PACKAGE_DIR)/priv $(APP_DIR)
endef
