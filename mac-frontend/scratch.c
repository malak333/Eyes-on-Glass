#include <stdio.h>
#include <sys/socket.h>

int main() {
    printf("SOL_SOCKET: %d\n", SOL_SOCKET);
    printf("SO_TIMESTAMP: %d\n", SO_TIMESTAMP);
    printf("SCM_TIMESTAMP: %d\n", SCM_TIMESTAMP);
}
