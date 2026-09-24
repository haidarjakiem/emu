#include <dlfcn.h>
#include <limits.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <GameController/GameController.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

#include "SDL2264Names.inc"
#include "SDL2264Indices.h"

static void *functions[833];
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int ready;
static char *(*native_base_path)(void);
static SDL_Window *(*native_create_window)(const char *, int, int, int, int, Uint32);
static void *(*native_get_metal_layer)(SDL_Renderer *);
static int (*native_send_virtual_key)(Uint8, SDL_Scancode);
static Uint32 (*native_relative_mouse)(int *, int *);
static Uint32 (*native_mouse_state)(int *, int *);
static int (*native_set_relative_mouse)(SDL_bool);
static void (*native_warp_mouse)(SDL_Window *, int, int);
static int (*native_show_cursor)(int);
static Sint16 (*native_controller_axis)(SDL_GameController *, SDL_GameControllerAxis);
static int (*native_poll_event)(SDL_Event *);
static atomic_bool touch_mouse;
static atomic_bool touch_down, requested_relative;
static atomic_uint last_touch_up;
static BOOL touch_pointer_routing;
static BOOL diagnostics;
void SRInstallMenuControls(UIWindowScene *, int (*)(Uint8, SDL_Scancode));

int32_t SDL_DYNAPI_entry(uint32_t version, void *table, uint32_t size);

static BOOL UsesTouchPointer(void) {
    return touch_pointer_routing && GCMouse.mice.count == 0;
}

static BOOL GameCapturesPointer(void) {
    // Cursor visibility alone is insufficient: controller-driven menus may
    // hide their pointer too. Use the game's explicit camera-lock request.
    return atomic_load(&requested_relative);
}

static int guest_set_relative_mouse(SDL_bool enabled) {
    atomic_store(&requested_relative, enabled == SDL_TRUE);
    // A finger supplies an absolute screen position. Desktop pointer locking
    // must not turn that position into camera motion or pin it to screen center.
    return native_set_relative_mouse(UsesTouchPointer() ? SDL_FALSE : enabled);
}

static void guest_warp_mouse(SDL_Window *window, int x, int y) {
    Uint32 (*ticks)(void) = functions[index_SDL_GetTicks];
    BOOL finishingTap = atomic_load(&last_touch_up) && (Uint32)(ticks() - atomic_load(&last_touch_up)) < 120;
    if (UsesTouchPointer() && (GameCapturesPointer() || atomic_load(&touch_down) || finishingTap)) return;
    native_warp_mouse(window, x, y);
}

static int guest_poll_event(SDL_Event *event) {
    if (!event) return native_poll_event(NULL);
    while (native_poll_event(event)) {
        // UIKit SDL already converts these touches to real mouse events.
        // The Mac game's finger-event branch reads mouse/keyboard union fields
        // from the incompatible finger structure, causing duplicate bad input.
        if (event->type == SDL_FINGERDOWN || event->type == SDL_FINGERUP ||
            event->type == SDL_FINGERMOTION) continue;
        return 1;
    }
    return 0;
}

static int WatchMouseSource(void *unused, SDL_Event *event) {
    if (event->type == SDL_MOUSEMOTION) {
        atomic_store(&touch_mouse, event->motion.which == SDL_TOUCH_MOUSEID);
    } else if ((event->type == SDL_MOUSEBUTTONDOWN || event->type == SDL_MOUSEBUTTONUP) &&
               event->button.which == SDL_TOUCH_MOUSEID) {
        atomic_store(&touch_mouse, true);
        if (event->button.button == SDL_BUTTON_LEFT) {
            atomic_store(&touch_down, event->type == SDL_MOUSEBUTTONDOWN);
            if (event->type == SDL_MOUSEBUTTONUP) {
                Uint32 (*ticks)(void) = functions[index_SDL_GetTicks];
                atomic_store(&last_touch_up, ticks());
            }
        }
        static unsigned reports;
        if (diagnostics && reports++ < 64) fprintf(stderr, "TouchMouse: %s at %d,%d cursor=%d capture=%d\n",
            event->type == SDL_MOUSEBUTTONDOWN ? "down" : "up", event->button.x, event->button.y,
            native_show_cursor(SDL_QUERY), atomic_load(&requested_relative));
    }
    return 0;
}

static Uint32 guest_relative_mouse(int *x, int *y) {
    int dx = 0, dy = 0;
    Uint32 buttons = native_relative_mouse(&dx, &dy);
    // Preserve normal mouse input in menus. Only the game's captured-camera
    // mode suppresses touch deltas; absolute positions and button states survive.
    if (UsesTouchPointer() && atomic_load(&touch_mouse) && GameCapturesPointer()) dx = dy = 0;
    if (x) *x = dx;
    if (y) *y = dy;
    return buttons;
}

static Uint32 guest_mouse_state(int *x, int *y) {
    int actualX = 0, actualY = 0;
    Uint32 buttons = native_mouse_state(&actualX, &actualY);
    static unsigned reports;
    static Uint32 previous;
    if (diagnostics && atomic_load(&touch_mouse) && buttons != previous && reports++ < 32) {
        fprintf(stderr, "GameMouse: buttons=%u at %d,%d\n", buttons, actualX, actualY);
        previous = buttons;
    }
    if (x) *x = actualX;
    if (y) *y = actualY;
    return buttons;
}

static Sint16 guest_controller_axis(SDL_GameController *controller, SDL_GameControllerAxis axis) {
    Sint16 value = native_controller_axis(controller, axis);
    if ((axis == SDL_CONTROLLER_AXIS_RIGHTX || axis == SDL_CONTROLLER_AXIS_RIGHTY) && atomic_load(&touch_down)) {
        const char *(*name)(SDL_GameController *) = functions[index_SDL_GameControllerName];
        const char *controllerName = name(controller);
        if (controllerName && strcmp(controllerName, "SnowRunner Touch") == 0) value = 0;
    }
    static Sint16 previous[SDL_CONTROLLER_AXIS_MAX];
    static unsigned reports;
    if (diagnostics && axis >= 0 && axis < SDL_CONTROLLER_AXIS_MAX && value != previous[axis] && reports < 80) {
        if (abs(value - previous[axis]) > 2048 || value == 0) {
            SDL_Window *(*focus)(void) = functions[index_SDL_GetKeyboardFocus];
            fprintf(stderr, "GameAxis: axis=%d value=%d focus=%d\n", axis, value, focus() != NULL);
            previous[axis] = value;
            ++reports;
        }
    }
    return value;
}

static char *guest_base_path(void) {
    const char *root = getenv("SNOW_RESOURCE_ROOT");
    if (!root || !*root) return native_base_path();
    size_t size = strlen(root);
    void *(*allocate)(size_t) = functions[index_SDL_malloc];
    char *path = allocate(size + 2);
    if (!path) return NULL;
    memcpy(path, root, size);
    if (root[size - 1] != '/') path[size++] = '/';
    path[size] = 0;
    return path;
}

static SDL_Window *guest_create_window(const char *title, int x, int y, int w, int h, Uint32 flags) {
    Dl_info caller = {0};
    if (dladdr(__builtin_return_address(0), &caller) && caller.dli_fname &&
        strstr(caller.dli_fname, "/GameClient.framework/GameClient")) {
        touch_pointer_routing = YES;
        fprintf(stderr, "SDLBridge: creating game window\n");
    }
    SDL_Window *window = native_create_window(title, x, y, w, h, flags);
    if (!window) return NULL;
    static BOOL watchingMouse;
    if (!watchingMouse) {
        void (*watch)(SDL_EventFilter, void *) = functions[index_SDL_AddEventWatch];
        watch(WatchMouseSource, NULL);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil usingBlock:^(NSNotification *notification) {
            atomic_store(&touch_down, false);
            atomic_store(&last_touch_up, 0);
            atomic_store(&touch_mouse, false);
        }];
        watchingMouse = YES;
    }
    SDL_SysWMinfo info;
    memset(&info, 0, sizeof(info));
    SDL_VERSION(&info.version);
    SDL_bool (*get_info)(SDL_Window *, SDL_SysWMinfo *) = functions[index_SDL_GetWindowWMInfo];
    if (get_info(window, &info) && info.subsystem == SDL_SYSWM_UIKIT) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindow *nativeWindow = info.info.uikit.window;
                if (nativeWindow.windowScene != scene) {
                    nativeWindow.hidden = YES;
                    nativeWindow.windowScene = (UIWindowScene *)scene;
                }
                nativeWindow.frame = ((UIWindowScene *)scene).coordinateSpace.bounds;
                nativeWindow.rootViewController.view.frame = nativeWindow.bounds;
                [nativeWindow makeKeyAndVisible];
                [nativeWindow layoutIfNeeded];
                [nativeWindow.rootViewController.view setNeedsLayout];
                [nativeWindow.rootViewController.view layoutIfNeeded];
                fprintf(stderr, "SDLBridge: window=%.0fx%.0f view=%.0fx%.0f orientation=%ld\n",
                        nativeWindow.bounds.size.width, nativeWindow.bounds.size.height,
                        nativeWindow.rootViewController.view.bounds.size.width,
                        nativeWindow.rootViewController.view.bounds.size.height,
                        (long)((UIWindowScene *)scene).interfaceOrientation);
                if (getenv("SNOW_RESOURCE_ROOT")) SRInstallMenuControls((UIWindowScene *)scene, native_send_virtual_key);
                break;
            }
        }
    }
    return window;
}

static void *guest_get_metal_layer(SDL_Renderer *renderer) {
    void *pointer = native_get_metal_layer(renderer);
    if (!pointer) return NULL;
    CAMetalLayer *layer = (__bridge CAMetalLayer *)pointer;
    static CGSize previousBounds, previousDrawable;
    static unsigned reports;
    CGSize bounds = layer.bounds.size, drawable = layer.drawableSize;
    if (diagnostics && reports < 12 && (!CGSizeEqualToSize(bounds, previousBounds) ||
                         !CGSizeEqualToSize(drawable, previousDrawable))) {
        fprintf(stderr, "SDLBridge: Metal bounds=%.0fx%.0f drawable=%.0fx%.0f scale=%.1f\n",
                bounds.width, bounds.height, drawable.width, drawable.height, layer.contentsScale);
        previousBounds = bounds;
        previousDrawable = drawable;
        ++reports;
    }
    return pointer;
}

static void load_functions(void) {
    diagnostics = getenv("EMU_DIAGNOSTICS") != NULL;
    Dl_info image;
    char directory[PATH_MAX];
    char path[PATH_MAX];
    if (!dladdr((void *)&SDL_DYNAPI_entry, &image)) return;
    if (strlcpy(directory, image.dli_fname, sizeof(directory)) >= sizeof(directory)) return;
    char *slash = strrchr(directory, '/');
    if (!slash) return;
    *slash = 0;
    slash = strrchr(directory, '/');
    if (!slash) return;
    *slash = 0;
    if (snprintf(path, sizeof(path), "%s/SDL2.framework/SDL2", directory) >= sizeof(path)) return;
    void *library = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!library) {
        fprintf(stderr, "SDLBridge: %s\n", dlerror());
        return;
    }
    for (unsigned i = 0; i < 833; ++i) {
        functions[i] = dlsym(library, sdl_names[i]);
        if (!functions[i]) {
            fprintf(stderr, "SDLBridge: missing %s\n", sdl_names[i]);
            return;
        }
    }
    native_send_virtual_key = dlsym(library, "SDL_SendVirtualKeyboardKey");
    if (!native_send_virtual_key) {
        fprintf(stderr, "SDLBridge: native virtual-keyboard entry point is missing\n");
        return;
    }
    native_base_path = functions[index_SDL_GetBasePath];
    functions[index_SDL_GetBasePath] = guest_base_path;
    native_create_window = functions[index_SDL_CreateWindow];
    functions[index_SDL_CreateWindow] = guest_create_window;
    native_get_metal_layer = functions[index_SDL_RenderGetMetalLayer];
    functions[index_SDL_RenderGetMetalLayer] = guest_get_metal_layer;
    native_relative_mouse = functions[index_SDL_GetRelativeMouseState];
    functions[index_SDL_GetRelativeMouseState] = guest_relative_mouse;
    native_mouse_state = functions[index_SDL_GetMouseState];
    functions[index_SDL_GetMouseState] = guest_mouse_state;
    native_set_relative_mouse = functions[index_SDL_SetRelativeMouseMode];
    functions[index_SDL_SetRelativeMouseMode] = guest_set_relative_mouse;
    native_warp_mouse = functions[index_SDL_WarpMouseInWindow];
    functions[index_SDL_WarpMouseInWindow] = guest_warp_mouse;
    native_show_cursor = functions[index_SDL_ShowCursor];
    native_controller_axis = functions[index_SDL_GameControllerGetAxis];
    functions[index_SDL_GameControllerGetAxis] = guest_controller_axis;
    native_poll_event = functions[index_SDL_PollEvent];
    functions[index_SDL_PollEvent] = guest_poll_event;
    ready = 1;
}

NSDictionary *SRMouseRoutingTest(SDL_Window *window) {
    if (!window || !ready) return @{@"passed":@NO, @"error":@"No SDL window"};
    if (GCMouse.mice.count) return @{@"passed":@NO, @"error":@"Physical mouse connected"};
    SDL_bool (*getRelative)(void) = functions[index_SDL_GetRelativeMouseMode];
    SDL_bool oldRelative = getRelative();
    int oldCursor = native_show_cursor(SDL_QUERY), oldX = 0, oldY = 0;
    native_mouse_state(&oldX, &oldY);
    BOOL oldRouting = touch_pointer_routing;
    BOOL oldRequested = atomic_load(&requested_relative), oldTouch = atomic_load(&touch_mouse), oldDown = atomic_load(&touch_down);
    Uint32 oldUp = atomic_load(&last_touch_up);
    touch_pointer_routing = YES;
    atomic_store(&touch_down, false);
    atomic_store(&last_touch_up, 0);

    BOOL acceptedCapture = guest_set_relative_mouse(SDL_TRUE) == 0;
    BOOL absoluteTouch = getRelative() == SDL_FALSE;
    native_warp_mouse(window, 120, 90);
    guest_warp_mouse(window, 400, 200);
    int x = 0, y = 0;
    native_mouse_state(&x, &y);
    BOOL cameraWarpIgnored = x == 120 && y == 90;

    guest_set_relative_mouse(SDL_FALSE);
    native_show_cursor(SDL_ENABLE);
    guest_warp_mouse(window, 164, 112);
    native_mouse_state(&x, &y);
    BOOL menuPointerWorks = x == 164 && y == 112;
    SDL_Event fingerMouse = {0};
    fingerMouse.type = SDL_MOUSEBUTTONDOWN;
    fingerMouse.button.which = SDL_TOUCH_MOUSEID;
    fingerMouse.button.button = SDL_BUTTON_LEFT;
    fingerMouse.button.x = x; fingerMouse.button.y = y;
    WatchMouseSource(NULL, &fingerMouse);
    guest_warp_mouse(window, 400, 200);
    native_mouse_state(&x, &y);
    BOOL touchAnchorPreserved = x == 164 && y == 112;
    fingerMouse.type = SDL_MOUSEBUTTONUP;
    WatchMouseSource(NULL, &fingerMouse);
    guest_warp_mouse(window, 400, 200);
    native_mouse_state(&x, &y);
    BOOL releaseAnchorPreserved = x == 164 && y == 112;

    touch_pointer_routing = oldRouting;
    atomic_store(&requested_relative, oldRequested);
    atomic_store(&touch_mouse, oldTouch);
    atomic_store(&touch_down, oldDown);
    atomic_store(&last_touch_up, oldUp);
    native_show_cursor(oldCursor);
    native_set_relative_mouse(oldRelative);
    native_warp_mouse(window, oldX, oldY);
    return @{@"captureRequestHandled":@(acceptedCapture), @"nativeTouchStaysAbsolute":@(absoluteTouch),
             @"cameraWarpIgnored":@(cameraWarpIgnored), @"menuPointerWorks":@(menuPointerWorks),
             @"touchAnchorPreserved":@(touchAnchorPreserved), @"releaseAnchorPreserved":@(releaseAnchorPreserved),
             @"passed":@(acceptedCapture && absoluteTouch && cameraWarpIgnored && menuPointerWorks && touchAnchorPreserved && releaseAnchorPreserved)};
}

int32_t SDL_DYNAPI_entry(uint32_t version, void *table, uint32_t size) {
    if (version != 1 || !table || size > sizeof(functions) || size % sizeof(void *)) return -1;
    pthread_once(&once, load_functions);
    if (!ready) return -1;
    memcpy(table, functions, size);
    return 0;
}
