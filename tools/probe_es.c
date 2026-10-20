#include <EndpointSecurity/EndpointSecurity.h>
#include <stdio.h>
int main(void) {
    es_client_t *client = NULL;
    es_new_client_result_t result = es_new_descendants_client(&client,
        ^(es_client_t *c, const es_message_t *m) {});
    printf("{\"es_new_descendants_client_result\":%u,\"available\":%s}\n", result,
           result == ES_NEW_CLIENT_RESULT_SUCCESS ? "true" : "false");
    if (client) es_delete_client(client);
    return 0;
}
