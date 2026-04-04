REBAR=./rebar

SRC_CODEC=../tm-backend-ejabberd-service/xmpp_codec.spec
DEST_CODEC=./deps/xmpp/xmpp_codec.spec

.PHONY: all compile clean shell check

all: compile

## Step 1: Validate source exists
check:
	@echo "Checking xmpp_codec.spec..."
	@test -f $(SRC_CODEC) || (echo "ERROR: $(SRC_CODEC) not found!" && exit 1)

## Step 2: Copy only if needed
$(DEST_CODEC): $(SRC_CODEC) check
	@echo "👀 Copying xmpp_codec.spec..."
	cp $(SRC_CODEC) $(DEST_CODEC)

## Step 3: Compile depends on copied file
compile: $(DEST_CODEC)
	@echo "Compiling project..."
	$(REBAR) compile

clean:
	@echo "Cleaning..."
	$(REBAR) clean

shell:
	@echo "Starting Erlang shell..."
	erl -pa ebin -pz deps/*/ebin
