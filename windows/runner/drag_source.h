#ifndef RUNNER_DRAG_SOURCE_H_
#define RUNNER_DRAG_SOURCE_H_

#include <windows.h>
#include <objidl.h>
#include <wrl/client.h>

#include <string>
#include <vector>

// The files at |paths| as Explorer drags them (the shell's own data object:
// CF_HDROP, the shell's ID lists, its drag image); null when none of them
// is there.
Microsoft::WRL::ComPtr<IDataObject> FileDataObject(
    const std::vector<std::wstring>& paths);

// Whether the left button is held down: the system's drag goes on with it.
bool LeftButtonDown();

// Goes on with Flutter's drag of |data|'s files out of |view| (the pointer,
// held down, left the window) as the system drags files, as
// MainFlutterWindow.swift's FileDropView does: let go in Explorer they are
// copied; back over the window, its DropTarget takes them as other apps'.
// Returns once they are let go (the system's drag has its own message loop,
// which keeps Flutter going). Flutter, which saw the button go down but not
// up (the drag took the mouse), is then told it went up, away from all, so
// that its own drag ends with nothing taking it.
void DragFilesOut(HWND view, IDataObject* data);

#endif  // RUNNER_DRAG_SOURCE_H_
