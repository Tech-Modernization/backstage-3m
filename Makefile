.DEFAULT_GOAL := help
COMPOSE_RUN_NODE := docker compose run --rm node
COMPOSE_RUN_YQ := docker compose run --rm yq
COMPOSE_RUN_TF := docker compose run --rm terraform
COMPOSE_RUN_TFLINT := docker compose run --rm tflint
COMPOSE_RUN_CHECKOV := docker compose run --rm checkov
COMPOSE_BUILD_BACKSTAGE := docker compose build backstage
COMPOSE_UP_NODE := docker compose --profile node up
COMPOSE_UP_BACKSTAGE := docker compose --profile docker up
ENVFILE ?= env.template

.DEFAULT_GOAL = help

all:
	ENVFILE=env.example $(MAKE) ci
.PHONY: all

ci: envfile _clean envfile ciInfra ciApp	
.PHONY: ci

ciApp: _deps _fmt _lint _tsc _test _build
.PHONY: ciApp

ciInfra: _tffmt _tfinit _tflint _tfvalidate _checkov _tfplan
.PHONY: ciInfra

bootstrap: ## Ran first to initially bootstrap
	$(COMPOSE_RUN_NODE) make _bootstrap
	$(COMPOSE_RUN_YQ) make _bootstrap
.PHONY: bootstrap

_bootstrap:
	npx @backstage/create-app@latest --path .
	git checkout -- .gitignore .prettierignore README.md
.PHONY: _bootstrap

_configure:
	yq e '.app |= (. + {"listen": {"host": "0.0.0.0" } })' -i app-config.yaml
	yq e '.backend.listen |= (. + {"host": "0.0.0.0" })' -i app-config.yaml
.PHONY: _configure

envfile: ## generate a .env file
	cp -f $(ENVFILE) .env
.PHONY: envfile

shell: ## jump into a shell with node
	$(COMPOSE_RUN_NODE) bash
.PHONY: shell

deps: ## installs dependencies
	$(COMPOSE_RUN_NODE) make _deps
.PHONY: deps

_deps:
	yarn install
.PHONY: _deps

dev: ## runs the dev app
	COMPOSE_COMMAND="make _dev" $(COMPOSE_UP_NODE)
	@until $(COMPOSE_RUN_NODE) curl -s -o /dev/null http://node:3000; do echo 'Waiting for frontend...'; sleep 1; done
	@until $(COMPOSE_RUN_NODE) curl -s -o /dev/null http://node:7007; do echo 'Waiting for backend...'; sleep 1; done
.PHONY: dev

_dev:
	yarn dev
.PHONY: _dev

fmt: ## formats files
	$(COMPOSE_RUN_NODE) make _fmt
.PHONY: fmt

_fmt:
	yarn prettier:check
.PHONY: _fmt

tsc: ## runs typscript compiler
	$(COMPOSE_RUN_NODE) make _tsc
.PHONY: tsc

_tsc:
	yarn tsc:full
.PHONY: _tsc

lint: ## lints the code (static checks)
	$(COMPOSE_RUN_NODE) make _lint
.PHONY: lint

_lint:
	yarn lint:all
.PHONY: _lint

build: ## builds distribution
	$(COMPOSE_RUN_NODE) make _build
.PHONY: build

_build:
	yarn build:backend
.PHONY: _build

test: ## runs tests
	$(COMPOSE_RUN_NODE) make _test
.PHONY: test

_test:
	yarn test:all
.PHONY: _test

package: ## build docker image
	$(COMPOSE_BUILD_BACKSTAGE)
.PHONY: package

run: ## run docker image
	$(COMPOSE_UP_BACKSTAGE)
.PHONY: run

tffmt: ## format terraform
	$(COMPOSE_RUN_TF) fmt -recursive -check
.PHONY: tffmt

_tffmt:
	cd infra && terraform fmt -recursive -check
.PHONY: _tffmt

tflint: ## lint terraform
	$(COMPOSE_RUN_TFLINT) --init
	$(COMPOSE_RUN_TFLINT)
.PHONY: tflint

_tflint:
	cd infra && tflint --init && tflint
.PHONY: _tflint

tfinit: ## init terraform
	$(COMPOSE_RUN_TF) init
.PHONY: tfinit

_tfinit:
	cd infra && terraform init
.PHONY: _tfinit

tfvalidate: ## validate terraform
	$(COMPOSE_RUN_TF) validate -no-color
.PHONY: tfvalidate

_tfvalidate:
	cd infra && terraform validate -no-color
.PHONY: _tfvalidate

checkov: ## run checkov
	$(COMPOSE_RUN_CHECKOV)
.PHONY: checkov

_checkov:
	checkov --show-config
.PHONY: _checkov

tfplan: ## plan terraform
	$(COMPOSE_RUN_TF) plan -no-color -input=false -out tfplan.out
	$(COMPOSE_RUN_TF) show -json tfplan.out > infra/tfplan.json
	$(COMPOSE_RUN_TF) show -no-color tfplan.out > infra/tfplan.txt
.PHONY: tfplan

_tfplan:
	cd infra && terraform plan -no-color -input=false -out tfplan.out && terraform show -json tfplan.out > tfplan.json && terraform show -no-color tfplan.out > tfplan.txt
.PHONY: _tfplan

tfapply:
	$(COMPOSE_RUN_TF) apply -input=false tfplan.out
.PHONY: tfapply

_tfapply:
	cd infra && terraform apply -input=false tfplan.out
.PHONY: _tfapply

cleanDocker: ## Tear down docker
	docker-compose down --remove-orphans
.PHONY: cleanDocker

clean: ## Clean up the workspace
	$(COMPOSE_RUN_NODE) make _clean
	$(MAKE) cleanDocker
.PHONY: clean

_clean:
	yarn clean
	rm -rf infra/tfplan.* results.sarif infra/terraform.tfstate*
.PHONY: _clean

upgrade: ## Upgrade Backstage version
	$(COMPOSE_RUN_NODE) _upgrade
.PHONY: upgrade

_upgrade:
	yarn backstage-cli versions:bump
.PHONY: upgrade

help: ## Show this help.
	$(COMPOSE_RUN_NODE) make _help
.PHONY: help

_help:
	@fgrep -h "##" $(MAKEFILE_LIST) | fgrep -v fgrep | sed -e 's/\\$$//' | sed -e 's/##//'
.PHONY: _help
