/*
 * A target that links the production C agent and runs one polled session
 * against the coordinator named by REPRO_HCR_AGENT_SOCKET. Used by
 * t_integration_hcr_patch_channel_admits_only_this_users_peer.nim to show
 * that the agent sends nothing to a listener of another uid. argv[1] is the
 * support profile the hello would carry.
 */
#include <stdio.h>

#include "repro_hcr_agent.h"

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: hcr_peer_target <support-profile>\n");
    return 2;
  }
  int started = repro_hcr_agent_start_polling_from_env(argv[1], NULL, 0);
  int polled = repro_hcr_agent_poll();
  printf("started=%d poll=%d session_open=%d\n", started, polled,
         repro_hcr_agent_poll_session_open());
  return 0;
}
