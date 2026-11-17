.PHONY: check

check:
	bash -n dispatch.sh install.sh examples/smoke-test.sh
	python3 test/test_dispatch.py
