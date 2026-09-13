PYTHON ?= python3
PSQL = $(PYTHON) scripts/psql.py -P pager=off

.PHONY: run prepare load refresh check test test-real

run:
	$(PSQL) -f sql/00-create-order-fact.sql -f sql/02-create-customer-datamart.sql -f sql/01-load-dwh.sql -f sql/03-update-customer-datamart.sql -f sql/04-check-results.sql

prepare:
	$(PSQL) -f sql/00-create-order-fact.sql -f sql/02-create-customer-datamart.sql

load:
	$(PSQL) -f sql/01-load-dwh.sql

refresh:
	$(PSQL) -f sql/03-update-customer-datamart.sql

check:
	$(PSQL) -f sql/04-check-results.sql

test:
	$(PYTHON) tests/run.py

test-real:
	$(PYTHON) tests/run.py --live-sources
