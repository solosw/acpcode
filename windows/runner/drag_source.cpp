#include "drag_source.h"

#include <shlobj.h>
#include <shobjidl.h>

#include <chrono>
#include <thread>

using Microsoft::WRL::ComPtr;

ComPtr<IDataObject> FileDataObject(const std::vector<std::wstring>& paths) {
  std::vector<PIDLIST_ABSOLUTE> items;
  for (const std::wstring& path : paths) {
    PIDLIST_ABSOLUTE item = nullptr;
    if (SUCCEEDED(::SHParseDisplayName(path.c_str(), nullptr, &item, 0,
                                       nullptr))) {
      items.push_back(item);
    }
  }
  ComPtr<IDataObject> data;
  if (!items.empty()) {
    // The items may be in different folders (a selection across the tree):
    // a shell item array makes one data object of them all.
    std::vector<PCIDLIST_ABSOLUTE> ids(items.begin(), items.end());
    ComPtr<IShellItemArray> array;
    if (SUCCEEDED(::SHCreateShellItemArrayFromIDLists(
            static_cast<UINT>(ids.size()),
            reinterpret_cast<PCIDLIST_ABSOLUTE_ARRAY>(ids.data()), &array))) {
      array->BindToHandler(nullptr, BHID_DataObject, IID_PPV_ARGS(&data));
    }
  }
  for (PIDLIST_ABSOLUTE item : items) {
    ::CoTaskMemFree(item);
  }
  return data;
}

bool LeftButtonDown() {
  // The button as the window's messages have it, swapped buttons and all.
  return (::GetKeyState(VK_LBUTTON) & 0x8000) != 0;
}

void DragFilesOut(HWND view, IDataObject* data) {
  DWORD effect = DROPEFFECT_NONE;
  // Without a drop source of its own, the shell makes one, and the drag
  // image from the data object's items (OLE is up: OleInitialize, see
  // main.cpp). Copied, as VS Code's explorer gives them: never moved out of
  // the project.
  ::SHDoDragDrop(view, data, nullptr, DROPEFFECT_COPY, &effect);

  // After the drop, which a DropTarget of the app's told Flutter of first.
  // Posted from elsewhere: PostMessage may be called from any thread, and a
  // window gone by then takes none.
  std::thread([view]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    ::PostMessageW(view, WM_LBUTTONUP, 0, MAKELPARAM(-30000, -30000));
  }).detach();
}
