STACK_NAME=${STACK_NAME:-"$(whoami)-de-ucp-$((1 + RANDOM % 100))"}
TEMPLATES_FOLDER="heat-templates"
STACK_ENVIRONMENT=${STACK_ENVIRONMENT:-converged.yaml}

openstack stack create -t ${TEMPLATES_FOLDER}/top.yaml -e ${TEMPLATES_FOLDER}/env/$STACK_ENVIRONMENT $STACK_NAME
