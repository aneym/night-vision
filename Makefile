BUILD_DIR := /tmp/night-vision-tests

.PHONY: test

test:
	@mkdir -p "$(BUILD_DIR)"
	clang -std=c11 -Wall -Wextra -Werror tests/test_brightness_mapping.c -o "$(BUILD_DIR)/test_brightness_mapping"
	"$(BUILD_DIR)/test_brightness_mapping"
	bash tests/test_schedule_sync.sh
	bash -n nightvision install.sh app/build.sh
