#import <Foundation/Foundation.h>

BOOL vp_custom_installer_available(void);
int vp_uninstall_helper_main(int argc, char *argv[]);
NSDictionary *vp_handle_custom_install(NSDictionary *msg);
NSDictionary *vp_handle_custom_uninstall(NSDictionary *msg);
