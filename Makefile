DIR := ${CURDIR}

# There is no reason GOROOT should be set anymore. Unset it so it doesn't mess
# with our go toolchain detection/usage.
ifneq ($(GOROOT),)
	export GOROOT=
endif

E:=@
ifeq ($(V),1)
	E=
endif

cyan := $(shell which tput > /dev/null && tput setaf 6 2>/dev/null || echo "")
reset := $(shell which tput > /dev/null && tput sgr0 2>/dev/null || echo "")
bold  := $(shell which tput > /dev/null && tput bold 2>/dev/null || echo "")

.PHONY: default all help

default: build

all: build lint test

help:
	@echo "$(bold)Usage:$(reset) make $(cyan)<target>$(reset)"
	@echo
	@echo "$(bold)Build:$(reset)"
	@echo "  $(cyan)build$(reset)                                 - build all SPIRE binaries (default)"
	@echo "  $(cyan)artifact$(reset)                              - build SPIRE tarball artifact"
	@echo
	@echo "$(bold)Test:$(reset)"
	@echo "  $(cyan)test$(reset)                                  - run unit tests"
	@echo "  $(cyan)race-test$(reset)                             - run unit tests with race detection"
	@echo "  $(cyan)integration$(reset)                           - run integration tests (requires Docker images)"
	@echo "                                          support 'SUITES' variable for executing specific tests"
	@echo "                                          e.g. SUITES='suites/join-token suites/k8s' make integration"
	@echo
	@echo "$(bold)Build and test:$(reset)"
	@echo "  $(cyan)all$(reset)                                   - build all SPIRE binaries, lint the code, and run unit tests"
	@echo
	@echo "$(bold)Docker image:$(reset)"
	@echo "  $(cyan)images$(reset)                                - build all SPIRE Docker images"
	@echo "  $(cyan)spire-server-image$(reset)                    - build SPIRE server Docker image"
	@echo "  $(cyan)spire-agent-image$(reset)                     - build SPIRE agent Docker image"
	@echo "  $(cyan)k8s-workload-registrar-image$(reset)          - build Kubernetes Workload Registrar Docker image"
	@echo "  $(cyan)oidc-discovery-provider-image$(reset)         - build OIDC Discovery Provider Docker image"
	@echo "$(bold)Docker from scratch image:$(reset)"
	@echo "  $(cyan)scratch-images$(reset)                        - build all SPIRE Docker from scratch images"
	@echo "  $(cyan)spire-server-scratch-image$(reset)            - build SPIRE server Docker scratch image"
	@echo "  $(cyan)spire-agent-scratch-image$(reset)             - build SPIRE agent Docker scratch image"
	@echo "  $(cyan)k8s-workload-registrar-scratch-image$(reset)  - build Kubernetes Workload Registrar Docker scratch image"
	@echo "  $(cyan)oidc-discovery-provider-scratch-image$(reset) - build OIDC Discovery Provider Docker image"
	@echo "$(bold)Developer support:$(reset)"
	@echo "  $(cyan)dev-image$(reset)                             - build the development Docker image"
	@echo "  $(cyan)dev-shell$(reset)                             - run a shell in a development Docker container"
	@echo
	@echo "$(bold)Code generation:$(reset)"
	@echo "  $(cyan)generate$(reset)                              - generate protocol buffers and plugin interface code"
	@echo "  $(cyan)generate-check$(reset)                        - ensure generated code is up to date"
	@echo "  $(cyan)protogen$(reset)                              - compile protocol buffers"
	@echo "  $(cyan)protogen-check$(reset)                        - ensure generated protocol buffers are up to date"
	@echo "  $(cyan)plugingen$(reset)                             - generate plugin interface code"
	@echo "  $(cyan)plugingen-check$(reset)                       - ensure generated plugin interface code is up to date"
	@echo "  $(cyan)mockgen$(reset)                               - generate test mocks"
	@echo
	@echo "For verbose output set V=1"
	@echo "  for example: $(cyan)make V=1 build$(reset)"


############################################################################
# OS/ARCH detection
############################################################################
os1=$(shell uname -s)
os2=
ifeq ($(os1),Darwin)
os1=darwin
os2=osx
else ifeq ($(os1),Linux)
os1=linux
os2=linux
else
$(error unsupported OS: $(os1))
endif

arch1=$(shell uname -m)
ifeq ($(arch1),x86_64)
arch2=amd64
else ifeq ($(arch1),aarch64)
arch2=arm64
else
$(error unsupported ARCH: $(arch1))
endif

############################################################################
# Vars
############################################################################

build_dir := $(DIR)/.build/$(os1)-$(arch1)

go_version_full := $(shell cat .go-version)
go_version := $(go_version_full:.0=)
go_dir := $(build_dir)/go/$(go_version)
go_bin_dir := $(go_dir)/bin
go_url = https://storage.googleapis.com/golang/go$(go_version).$(os1)-$(arch2).tar.gz
go_path := PATH="$(go_bin_dir):$(PATH)"

golangci_lint_version = v1.27.0
golangci_lint_dir = $(build_dir)/golangci_lint/$(golangci_lint_version)
golangci_lint_bin = $(golangci_lint_dir)/golangci-lint

protoc_version = 3.14.0
ifeq ($(arch1),aarch64)
protoc_url = https://github.com/protocolbuffers/protobuf/releases/download/v$(protoc_version)/protoc-$(protoc_version)-$(os2)-aarch_64.zip
else
protoc_url = https://github.com/protocolbuffers/protobuf/releases/download/v$(protoc_version)/protoc-$(protoc_version)-$(os2)-$(arch1).zip
endif
protoc_dir = $(build_dir)/protoc/$(protoc_version)
protoc_bin = $(protoc_dir)/bin/protoc

protoc_gen_go_version := $(shell grep google.golang.org/protobuf go.mod | awk '{print $$2}')
protoc_gen_go_base_dir := $(build_dir)/protoc-gen-go
protoc_gen_go_dir := $(protoc_gen_go_base_dir)/$(protoc_gen_go_version)-go$(go_version)
protoc_gen_go_bin := $(protoc_gen_go_dir)/protoc-gen-go

protoc_gen_go_grpc_version := v1.0.1
protoc_gen_go_grpc_base_dir := $(build_dir)/protoc-gen-go-grpc
protoc_gen_go_grpc_dir := $(protoc_gen_go_grpc_base_dir)/$(protoc_gen_go_grpc_version)-go$(go_version)
protoc_gen_go_grpc_bin := $(protoc_gen_go_grpc_dir)/protoc-gen-go-grpc

mockgen_version := $(shell grep github.com/golang/mock go.mod | awk '{print $$2}')
mockgen_base_dir := $(build_dir)/mockgen
mockgen_dir := $(mockgen_base_dir)/$(mockgen_version)-go$(go_version)
mockgen_bin := $(mockgen_dir)/mockgen

# There may be more than one tag. Only use one that starts with 'v' followed by
# a number, e.g., v0.9.3.
git_tag := $(shell git tag --points-at HEAD | grep '^v[0-9]*')
git_hash := $(shell git rev-parse --short=7 HEAD)
git_dirty := $(shell git status -s)

protos := \
	proto/private/server/journal/journal.proto \
	proto/spire/common/common.proto \

serviceprotos := \
	proto/private/test/catalogtest/test.proto \
	proto/spire/agent/keymanager/keymanager.proto \
	proto/spire/agent/nodeattestor/nodeattestor.proto \
	proto/spire/agent/svidstore/svidstore.proto \
	proto/spire/agent/workloadattestor/workloadattestor.proto \
	proto/spire/api/registration/registration.proto \
	proto/spire/common/hostservices/metricsservice.proto \
	proto/spire/common/plugin/plugin.proto \
	proto/spire/server/datastore/datastore.proto \
	proto/spire/server/hostservices/agentstore.proto \
	proto/spire/server/hostservices/identityprovider.proto \
	proto/spire/server/keymanager/keymanager.proto \
	proto/spire/server/nodeattestor/nodeattestor.proto \
	proto/spire/server/noderesolver/noderesolver.proto \
	proto/spire/server/notifier/notifier.proto \
	proto/spire/server/upstreamauthority/upstreamauthority.proto \


# The following three variables define the plugin, service, and hostservice
# interfaces. The syntax of each entry is as follows:
#
# proto-path,out-path,interface-name[,shared]
#
# "shared" means that the interface shares a package with other interfaces, which
# impacts the code generation (adds stutter to disambiguate names)
plugingen_plugins = \
	proto/spire/server/notifier/notifier.proto,pkg/server/plugin/notifier,Notifier \
	proto/spire/server/nodeattestor/nodeattestor.proto,pkg/server/plugin/nodeattestor,NodeAttestor \
	proto/spire/server/datastore/datastore.proto,pkg/server/plugin/datastore,DataStore \
	proto/spire/server/upstreamauthority/upstreamauthority.proto,pkg/server/plugin/upstreamauthority,UpstreamAuthority \
	proto/spire/server/noderesolver/noderesolver.proto,pkg/server/plugin/noderesolver,NodeResolver \
	proto/spire/server/keymanager/keymanager.proto,pkg/server/plugin/keymanager,KeyManager \
	proto/spire/agent/nodeattestor/nodeattestor.proto,proto/spire/agent/nodeattestor/v0,NodeAttestor \
	proto/spire/agent/workloadattestor/workloadattestor.proto,proto/spire/agent/workloadattestor/v0,WorkloadAttestor \
	proto/spire/agent/keymanager/keymanager.proto,proto/spire/agent/keymanager/v0,KeyManager \
	proto/spire/agent/svidstore/svidstore.proto,pkg/agent/plugin/svidstore,SVIDStore \
	proto/private/test/catalogtest/test.proto,proto/private/test/catalogtest,Plugin,shared \

plugingen_services = \
	proto/private/test/catalogtest/test.proto,proto/private/test/catalogtest,Service,shared \

plugingen_hostservices = \
	proto/spire/server/hostservices/identityprovider.proto,pkg/server/plugin/hostservices,IdentityProvider,shared \
	proto/spire/server/hostservices/agentstore.proto,pkg/server/plugin/hostservices,AgentStore,shared \
	proto/spire/common/hostservices/metricsservice.proto,pkg/common/plugin/hostservices,MetricsService,shared \
	proto/private/test/catalogtest/test.proto,proto/private/test/catalogtest,HostService,shared \

# The following are the mock interfaces generated by mockgen. The syntax of each
# entry is as follows:
# mock-destination-pkg,src-go-pkg,interface[,additional interfaces]
mockgen_mocks = \
	test/mock/server/aws,github.com/spiffe/spire/pkg/server/plugin/nodeattestor/aws,Client \
	test/mock/agent/client,github.com/spiffe/spire/pkg/agent/client,Client \
	test/mock/common/plugin/k8s/apiserver,github.com/spiffe/spire/pkg/common/plugin/k8s/apiserver,Client \
	test/mock/common/plugin/k8s/clientset,k8s.io/client-go/kubernetes,Interface \
	test/mock/common/plugin/k8s/clientset/corev1,k8s.io/client-go/kubernetes/typed/core/v1,CoreV1Interface \
	test/mock/common/plugin/k8s/clientset/corev1/pod,k8s.io/client-go/kubernetes/typed/core/v1,PodInterface \
	test/mock/common/plugin/k8s/clientset/corev1/node,k8s.io/client-go/kubernetes/typed/core/v1,NodeInterface \
	test/mock/common/plugin/k8s/clientset/authenticationv1,k8s.io/client-go/kubernetes/typed/authentication/v1,AuthenticationV1Interface \
	test/mock/common/plugin/k8s/clientset/authenticationv1/tokenreview,k8s.io/client-go/kubernetes/typed/authentication/v1,TokenReviewInterface \
	test/mock/agent/plugin/workloadattestor/docker,github.com/spiffe/spire/pkg/agent/plugin/workloadattestor/docker,Docker \

# The following vars are used in rule construction
comma := ,
null  :=
space := $(null) #

#############################################################################
# Utility functions and targets
#############################################################################

.PHONY: git-clean-check

tolower = $(shell echo $1 | tr '[:upper:]' '[:lower:]')

goenv = $(shell PATH="$(go_bin_dir):$(PATH)" go env $1)

git-clean-check:
ifneq ($(git_dirty),)
	git diff
	@echo "Git repository is dirty!"
	@false
else
	@echo "Git repository is clean."
endif

############################################################################
# Determine go flags
############################################################################

# Flags passed to all invocations of go test
go_test_flags := -timeout=60s

go_flags :=
ifneq ($(GOPARALLEL),)
	# circleci executors don't have enough memory to run compilation with
	# high parallism
	go_flags += -p=$(GOPARALLEL)
endif

ifneq ($(GOVERBOSE),)
	# circleci executors don't have enough memory to run compilation with
	# high parallism
	go_flags += -v
endif

# Determine the ldflags passed to the go linker. The git tag and hash will be
# provided to the linker unless the git status is dirty.
go_ldflags := -s -w
ifeq ($(git_dirty),)
	ifneq ($(git_tag),)
		# Remove the "v" prefix from the git_tag for use as the version number.
		# e.g. 0.9.3 instead of v0.9.3
		git_version_tag := $(git_tag:v%=%)
		go_ldflags += -X github.com/spiffe/spire/pkg/common/version.gittag=$(git_version_tag)
	endif
	ifneq ($(git_hash),)
		go_ldflags += -X github.com/spiffe/spire/pkg/common/version.githash=$(git_hash)
	endif
endif
go_ldflags := '${go_ldflags}'

#############################################################################
# Build Targets
#############################################################################

.PHONY: build

build: tidy bin/spire-server bin/spire-agent bin/k8s-workload-registrar bin/oidc-discovery-provider

define binary_rule
.PHONY: $1
$1: | go-check bin/
	@echo Building $1...
	$(E)$(go_path) go build $$(go_flags) -ldflags $$(go_ldflags) -o $1 $2
endef

# main SPIRE binaries
$(eval $(call binary_rule,bin/spire-server,./cmd/spire-server))
$(eval $(call binary_rule,bin/spire-agent,./cmd/spire-agent))
$(eval $(call binary_rule,bin/k8s-workload-registrar,./support/k8s/k8s-workload-registrar))
$(eval $(call binary_rule,bin/oidc-discovery-provider,./support/oidc-discovery-provider))

# utilities
$(eval $(call binary_rule,bin/spire-plugingen,./tools/spire-plugingen))

bin/:
	@mkdir -p $@

#############################################################################
# Build Static binaries for scratch docker images
#############################################################################

.PHONY: build-static

build-static: tidy bin/spire-server-static bin/spire-agent-static bin/k8s-workload-registrar-static bin/oidc-discovery-provider-static

define binary_rule_static
.PHONY: $1
$1: | go-check bin/
	@echo Building $1...
	$(E)$(go_path) CGO_ENABLED=0 go build $$(go_flags) -ldflags $$(go_ldflags) -o $1 $2

endef
# https://7thzero.com/blog/golang-w-sqlite3-docker-scratch-image
define binary_rule_external_static
.PHONY: $1
$1: | go-check bin/
	@echo Building $1...
	$(E)$(go_path) CGO_ENABLED=1 go build $$(go_flags) -ldflags '-s -w -linkmode external -extldflags "-static"' -o $1 $2

endef

# static builds
$(eval $(call binary_rule_external_static,bin/spire-server-static,./cmd/spire-server))
$(eval $(call binary_rule_static,bin/spire-agent-static,./cmd/spire-agent))
$(eval $(call binary_rule_static,bin/k8s-workload-registrar-static,./support/k8s/k8s-workload-registrar))
$(eval $(call binary_rule_static,bin/oidc-discovery-provider-static,./support/oidc-discovery-provider))

#############################################################################
# Test Targets
#############################################################################

.PHONY: test race-test integration

test: | go-check
ifneq ($(COVERPROFILE),)
	$(E)$(go_path) go test $(go_flags) $(go_test_flags) -covermode=atomic -coverprofile="$(COVERPROFILE)" ./...
else
	$(E)$(go_path) go test $(go_flags) $(go_test_flags) ./...
endif

race-test: | go-check
ifneq ($(COVERPROFILE),)
	$(E)$(go_path) go test $(go_flags) $(go_test_flags) -race -coverprofile="$(COVERPROFILE)" ./...
else
	$(E)$(go_path) go test $(go_flags) $(go_test_flags) -race ./...
endif

integration:
	$(E)./test/integration/test.sh $(SUITES)

#############################################################################
# Build Artifact
#############################################################################

.PHONY: artifact

artifact: build
	$(E)OUTDIR="$(OUTDIR)" TAG="$(TAG)" ./script/build-artifact.sh

#############################################################################
# Docker Images
#############################################################################

.PHONY: images
images: spire-server-image spire-agent-image k8s-workload-registrar-image oidc-discovery-provider-image

.PHONY: spire-server-image
spire-server-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target spire-server -t spire-server .
	docker tag spire-server:latest spire-server:latest-local

.PHONY: spire-agent-image
spire-agent-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target spire-agent -t spire-agent .
	docker tag spire-agent:latest spire-agent:latest-local

.PHONY: k8s-workload-registrar-image
k8s-workload-registrar-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target k8s-workload-registrar -t k8s-workload-registrar .
	docker tag k8s-workload-registrar:latest k8s-workload-registrar:latest-local

.PHONY: oidc-discovery-provider-image
oidc-discovery-provider-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target oidc-discovery-provider -t oidc-discovery-provider .
	docker tag oidc-discovery-provider:latest oidc-discovery-provider:latest-local

#############################################################################
# Docker Images FROM scratch
#############################################################################

.PHONY: scratch-images
scratch-images: spire-server-scratch-image spire-agent-scratch-image k8s-workload-registrar-scratch-image

.PHONY: spire-server-scratch-image
spire-server-scratch-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target spire-server-scratch -t spire-server-scratch -f Dockerfile.scratch .
	docker tag spire-server-scratch:latest spire-server-scratch:latest-local

.PHONY: spire-agent-scratch-image
spire-agent-scratch-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target spire-agent-scratch -t spire-agent-scratch -f Dockerfile.scratch .
	docker tag spire-agent-scratch:latest spire-agent-scratch:latest-local

.PHONY: k8s-workload-registrar-scratch-image
k8s-workload-registrar-scratch-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target k8s-workload-registrar-scratch -t k8s-workload-registrar-scratch -f Dockerfile.scratch .
	docker tag k8s-workload-registrar-scratch:latest k8s-workload-registrar-scratch:latest-local

.PHONY: oidc-discovery-provider-scratch-image
oidc-discovery-provider-scratch-image: Dockerfile
	docker build --build-arg goversion=$(go_version_full) --target oidc-discovery-provider-scratch -t oidc-discovery-provider-scratch -f Dockerfile.scratch .
	docker tag oidc-discovery-provider-scratch:latest oidc-discovery-provider-scratch:latest-local

#############################################################################
# Code cleanliness
#############################################################################

.PHONY: tidy tidy-check lint lint-code
tidy: | go-check
	$(E)$(go_path) go mod tidy
	$(E)cd proto/spire; $(go_path) go mod tidy

tidy-check:
ifneq ($(git_dirty),)
	$(error tidy-check must be invoked on a clean repository)
endif
	@echo "Running go tidy..."
	$(E)$(MAKE) tidy
	@echo "Ensuring git repository is clean..."
	$(E)$(MAKE) git-clean-check

lint: lint-code

lint-code: $(golangci_lint_bin) | go-check
	$(E)PATH="$(go_bin_dir):$(PATH)" $(golangci_lint_bin) run ./...


#############################################################################
# Code Generation
#############################################################################

.PHONY: generate generate-check protogen protogen-check plugingen plugingen-check mocks

generate: protogen plugingen

generate-check: protogen-check plugingen-check

protogen: $(protos:.proto=.pb.go) $(serviceprotos:.proto=.pb.go) $(serviceprotos:.proto=_grpc.pb.go)

%_grpc.pb.go: %.proto $(protoc_bin) $(protoc_gen_go_grpc_bin)
	@echo "(proto) compiling service $<..."
	$(E)cd proto && \
		PATH="$(protoc_gen_go_grpc_dir):$(PATH)" \
		$(protoc_bin) \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		$(<:proto/%=%)

%.pb.go: %.proto $(protoc_bin) $(protoc_gen_go_bin)
	@echo "(proto) compiling $<..."
	$(E)cd proto && \
		PATH="$(protoc_gen_go_dir):$(PATH)" \
		$(protoc_bin) \
		--go_out=. --go_opt=paths=source_relative \
		$(<:proto/%=%)

protogen-check:
ifneq ($(git_dirty),)
	$(error protogen-check must be invoked on a clean repository)
endif
	$(E)find . -type f -name "*.proto" -exec touch {} \;
	@echo "Compiling protocol buffers..."
	$(E)$(MAKE) protogen
	@echo "Ensuring git repository is clean..."
	$(E)$(MAKE) git-clean-check

plugingen-proto = $(word 1,$(subst $(comma),$(space),$1))
plugingen-grpc-pbgo = $(subst .proto,_grpc.pb.go,$(call plugingen-proto,$1))
plugingen-pbgo = $(subst .proto,_grpc.pb.go,$(call plugingen-proto,$1))
plugingen-proto-dir = $(dir $(call plugingen-proto, $1))
plugingen-out-dir = $(word 2,$(subst $(comma),$(space),$1))
plugingen-type = $(word 3,$(subst $(comma),$(space),$1))
plugingen-shared = $(word 4,$(subst $(comma),$(space),$1))
plugingen-shared-opt = $(subst shared,-shared,$(call plugingen-shared,$1))
plugingen-out = $(call plugingen-out-dir,$1)/$(call tolower,$(call plugingen-type,$1)).go

# plugingen-rule is a template for invoking spire-plugingen and is invoked with a plugingen_* entry
define plugingen-rule
$(call plugingen-out,$1): $(call plugingen-grpc-pbgo,$1) $(call plugingen-pbgo,$1) | bin/spire-plugingen
	@echo "($2) generating $$@..."
	$(E)PATH="$$(go_bin_dir):$$(PATH)" $$(DIR)/bin/spire-plugingen $(call plugingen-shared-opt,$1) -mode $2 -out $(call plugingen-out-dir,$1) $(call plugingen-proto-dir,$1) $(call plugingen-type,$1)
endef

# generate rules for plugins
$(foreach x,$(plugingen_plugins),$(eval $(call plugingen-rule,$(x),plugin)))
#
# generate rules for services
$(foreach x,$(plugingen_services),$(eval $(call plugingen-rule,$(x),service)))

# generate rules for hostservices
$(foreach x,$(plugingen_hostservices),$(eval $(call plugingen-rule,$(x),hostservice)))

plugingen-plugins: $(foreach x,$(plugingen_plugins),$(call plugingen-out,$x))

plugingen-services: $(foreach x,$(plugingen_services),$(call plugingen-out,$x))

plugingen-hostservices: $(foreach x,$(plugingen_hostservices),$(call plugingen-out,$x))

plugingen: protogen plugingen-plugins plugingen-services plugingen-hostservices

plugingen-check:
ifneq ($(git_dirty),)
	$(error plugingen-check must be invoked on a clean repository)
endif
	$(E)find . -type f -name "*.pb.go" -exec touch {} \;
	@echo "Generating plugin interface code..."
	$(E)$(MAKE) plugingen
	@echo "Ensuring git repository is clean..."
	$(E)$(MAKE) git-clean-check

mockgen-pkg = $(word 1,$(subst $(comma),$(space),$1))
mockgen-pkgname = $(notdir $(call mockgen-pkg,$1))
mockgen-src = $(word 2,$(subst $(comma),$(space),$1))
mockgen-intfs = $(subst $(space),$(comma),$(wordlist 3,99,$(subst $(comma),$(space),$1)))
mockgen-out = $(call mockgen-pkg,$1)/$(call mockgen-pkgname,$1).go

define mockgen-rule
$(call mockgen-out,$1): $$(mockgen_bin)
	@echo "(mockgen) generating $$@..."
	$(E)$$(mockgen_bin) -destination $(call mockgen-out,$1) -package mock_$(call mockgen-pkgname,$1) $(call mockgen-src,$1) $(call mockgen-intfs,$1)
endef

$(foreach x,$(mockgen_mocks),$(eval $(call mockgen-rule,$x)))

mockgen: $(foreach x,$(mockgen_mocks),$(call mockgen-out,$x))

#############################################################################
# Developer support
#############################################################################

.PHONY: dev-shell dev-image

dev-image:
	$(E)docker build -t spire-dev -f Dockerfile.dev .

dev-shell: | go-check
	$(E)docker run --rm -v "$(call goenv,GOCACHE)":/root/.cache/go-build -v "$(DIR):/spire" -v "$(call goenv,GOPATH)/pkg/mod":/root/go/pkg/mod -it -h spire-dev spire-dev

#############################################################################
# Toolchain
#############################################################################

# go-check checks to see if there is a version of Go available matching the
# required version. The build cache is preferred. If not available, it is
# downloaded into the build cache. Any rule needing to invoke tools in the go
# toolchain should depend on this rule and then prepend $(go_bin_dir) to their
# path before invoking go or use $(go_path) go which already has the path prepended.
# Note that some tools (e.g. anything that uses golang.org/x/tools/go/packages)
# execute on the go binary and also need the right path in order to locate the
# correct go binary.
go-check:
ifneq (go$(go_version), $(shell $(go_path) go version 2>/dev/null | cut -f3 -d' '))
	@echo "Installing go$(go_version)..."
	$(E)rm -rf $(dir $(go_dir))
	$(E)mkdir -p $(go_dir)
	$(E)curl -sSfL $(go_url) | tar xz -C $(go_dir) --strip-components=1
endif

go-bin-path: go-check
	@echo "$(go_bin_dir):${PATH}"

install-toolchain: install-protoc install-golangci-lint install-protoc-gen-go install-protoc-gen-doc install-mockgen | go-check

install-protoc: $(protoc_bin)

$(protoc_bin):
	@echo "Installing protoc $(protoc_version)..."
	$(E)rm -rf $(dir $(protoc_dir))
	$(E)mkdir -p $(protoc_dir)
	$(E)curl -sSfL $(protoc_url) -o $(build_dir)/tmp.zip; unzip -q -d $(protoc_dir) $(build_dir)/tmp.zip; rm $(build_dir)/tmp.zip

install-golangci-lint: $(golangci_lint_bin)

$(golangci_lint_bin):
	@echo "Installing golangci-lint $(golangci_lint_version)..."
	$(E)rm -rf $(dir $(golangci_lint_dir))
	$(E)mkdir -p $(golangci_lint_dir)
	$(E)curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(golangci_lint_dir) $(golangci_lint_version)

install-protoc-gen-go: $(protoc_gen_go_bin)

$(protoc_gen_go_bin): | go-check
	@echo "Installing protoc-gen-go $(protoc_gen_go_version)..."
	$(E)rm -rf $(protoc_gen_go_base_dir)
	$(E)mkdir -p $(protoc_gen_go_dir)
	$(E)$(go_path) go build -o $(protoc_gen_go_bin) google.golang.org/protobuf/cmd/protoc-gen-go

install-protoc-gen-go-grpc: $(protoc_gen_go_grpc_bin)

$(protoc_gen_go_grpc_bin): | go-check
	@echo "Installing protoc-gen-go-grpc $(protoc_gen_go_grpc_version)..."
	$(E)rm -rf $(protoc_gen_go_grpc_base_dir)
	$(E)mkdir -p $(protoc_gen_go_grpc_dir)
	$(E)echo "module tools" > $(protoc_gen_go_grpc_dir)/go.mod
	$(E)cd $(protoc_gen_go_grpc_dir) && GOBIN=$(protoc_gen_go_grpc_dir) $(go_path) go get google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(protoc_gen_go_grpc_version)

install-mockgen: $(mockgen_bin)

$(mockgen_bin): | go-check
	@echo "Installing mockgen $(mockgen_version)..."
	$(E)rm -rf $(mockgen_base_dir)
	$(E)mkdir -p $(mockgen_dir)
	$(E)$(go_path) go build -o $(mockgen_bin) github.com/golang/mock/mockgen
