// Run after the two virtual adapters have bonded. The service owns BlueZ's
// input PSMs on this machine, so connect the second adapter to the kernel
// HIDP host explicitly. Read the report descriptor off the radio through SDP.
#include <bluetooth/bluetooth.h>
#include <bluetooth/hidp.h>
#include <bluetooth/l2cap.h>
#include <bluetooth/sdp.h>
#include <bluetooth/sdp_lib.h>
#include <err.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <unistd.h>

static int channel(bdaddr_t local, bdaddr_t remote, unsigned psm)
{
    int fd = socket(AF_BLUETOOTH, SOCK_SEQPACKET, BTPROTO_L2CAP);
    struct sockaddr_l2 addr = { .l2_family = AF_BLUETOOTH, .l2_bdaddr = local };
    struct bt_security security = { .level = BT_SECURITY_MEDIUM };
    if (fd < 0 || bind(fd, (void *)&addr, sizeof(addr)) < 0 ||
        setsockopt(fd, SOL_BLUETOOTH, BT_SECURITY, &security, sizeof(security)) < 0)
        err(1, "binding host L2CAP channel");
    addr.l2_bdaddr = remote;
    addr.l2_psm = htobs(psm);
    if (connect(fd, (void *)&addr, sizeof(addr)) < 0) err(1, "connecting PSM %u", psm);
    return fd;
}

int main(int argc, char **argv)
{
    bdaddr_t local, remote;
    if (argc != 3 || str2ba(argv[1], &local) || str2ba(argv[2], &remote))
        errx(1, "usage: bluetooth-kernel-host HOST_ADDRESS DECK_ADDRESS");
    sdp_session_t *session = sdp_connect(&local, &remote, SDP_RETRY_IF_BUSY);
    if (!session) err(1, "connecting to the Deck's SDP server");
    uuid_t hid;
    sdp_uuid16_create(&hid, HID_SVCLASS_ID);
    uint32_t range = 0x0000ffff;
    sdp_list_t *search = sdp_list_append(NULL, &hid);
    sdp_list_t *attrs = sdp_list_append(NULL, &range), *records = NULL;
    if (sdp_service_search_attr_req(session, search, SDP_ATTR_REQ_RANGE, attrs, &records) < 0 || !records)
        errx(1, "no HID service advertised");
    sdp_data_t *desc = sdp_data_get(records->data, SDP_ATTR_HID_DESCRIPTOR_LIST);
    for (int level = 0; level < 2; level++) {
        if (!desc || !SDP_IS_SEQ(desc->dtd)) errx(1, "invalid HID descriptor list");
        desc = desc->val.dataseq;
    }
    if (!desc || desc->dtd != SDP_UINT8 || desc->val.uint8 != 0x22 ||
        !desc->next || !SDP_IS_TEXT_STR(desc->next->dtd)) errx(1, "missing report descriptor");
    desc = desc->next;
    struct hidp_connadd_req req = {
        .parser = 0x0111, .subclass = 8, .vendor = 0x28de, .product = 0x1303, .version = 0x0100,
        .rd_data = (uint8_t *) desc->val.str, .rd_size = desc->unitSize - 1, .name = "Steam Controller"
    };
    req.ctrl_sock = channel(local, remote, 0x11);
    req.intr_sock = channel(local, remote, 0x13);
    int ctl = socket(AF_BLUETOOTH, SOCK_RAW, BTPROTO_HIDP);
    if (ctl < 0 || ioctl(ctl, HIDPCONNADD, &req) < 0) err(1, "attaching kernel HIDP");
    close(ctl);
    close(req.intr_sock);
    close(req.ctrl_sock);
    sdp_list_free(records, (sdp_free_func_t)sdp_record_free);
    sdp_list_free(attrs, NULL);
    sdp_list_free(search, NULL);
    sdp_close(session);
    return 0;
}
