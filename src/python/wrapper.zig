const std = @import("std");

// Define the basic PyObject type
pub const PyObject = opaque {};

// Define PyMethodDef struct
pub const PyMethodDef = extern struct {
    ml_name: [*c]const u8,
    ml_meth: ?*const fn (?*PyObject, ?*PyObject) callconv(.C) ?*PyObject,
    ml_flags: c_int,
    ml_doc: [*c]const u8,
};

// Python method flags
pub const METH_VARARGS: c_int = 1;
pub const METH_KEYWORDS: c_int = 2;
pub const METH_NOARGS: c_int = 4;
pub const METH_O: c_int = 8;

// Export Python C functions directly through extern (now via wrapper functions)
// Basic reference counting
pub extern "c" fn zig_py_incref(obj: *PyObject) void;
pub extern "c" fn zig_py_decref(obj: *PyObject) void;

// Python interpreter initialization
pub extern "c" fn Py_Initialize() void;
pub extern "c" fn Py_Finalize() void;
pub extern "c" fn Py_IsInitialized() c_int;

// Basic object operations
pub extern "c" fn PyCallable_Check(obj: *PyObject) c_int;
pub extern "c" fn PyErr_Occurred() ?*PyObject;
pub extern "c" fn PyErr_Print() void;
pub extern "c" fn PyErr_Clear() void;
pub extern "c" fn PyErr_SetString(exception: *PyObject, message: [*c]const u8) void;

// Importing and modules
pub extern "c" fn PyImport_Import(name: *PyObject) ?*PyObject;
pub extern "c" fn PyImport_ImportModule(name: [*c]const u8) ?*PyObject;
pub extern "c" fn PyObject_GetAttr(obj: *PyObject, attr_name: *PyObject) ?*PyObject;
pub extern "c" fn PyObject_GetAttrString(obj: *PyObject, attr_name: [*c]const u8) ?*PyObject;

// Function calling
pub extern "c" fn PyObject_Call(callable: *PyObject, args: *PyObject, kwargs: ?*PyObject) ?*PyObject;
pub extern "c" fn PyObject_CallObject(callable: *PyObject, args: ?*PyObject) ?*PyObject;

// Dict operations
pub extern "c" fn PyDict_SetItem(dict: *PyObject, key: *PyObject, value: *PyObject) c_int;
pub extern "c" fn PyDict_Next(dict: *PyObject, pos: *c_long, key: *?*PyObject, value: *?*PyObject) c_int;
pub extern "c" fn PyDict_New() ?*PyObject;

// List operations
pub extern "c" fn PyList_SetItem(list: *PyObject, index: c_long, item: *PyObject) c_int;
pub extern "c" fn PyList_New(size: c_long) ?*PyObject;
pub extern "c" fn PyList_GetItem(list: *PyObject, index: c_long) ?*PyObject;
pub extern "c" fn PyList_Size(list: *PyObject) c_long;

// Tuple operations
pub extern "c" fn PyTuple_Size(tuple: *PyObject) c_long;
pub extern "c" fn PyTuple_GetItem(tuple: *PyObject, index: c_long) ?*PyObject;
pub extern "c" fn PyTuple_SetItem(tuple: *PyObject, index: c_long, item: *PyObject) c_int;
pub extern "c" fn PyTuple_New(size: c_long) ?*PyObject;

// Number operations
pub extern "c" fn PyLong_FromLongLong(value: c_longlong) ?*PyObject;
pub extern "c" fn PyLong_AsLongLong(obj: *PyObject) c_longlong;
pub extern "c" fn PyFloat_FromDouble(value: f64) ?*PyObject;
pub extern "c" fn PyFloat_AsDouble(obj: *PyObject) f64;

// String operations
pub extern "c" fn PyUnicode_FromStringAndSize(str: [*c]const u8, size: c_long) ?*PyObject;
pub extern "c" fn PyUnicode_AsUTF8(unicode: *PyObject) [*c]const u8;

// Type checking functions via our wrappers
pub extern "c" fn zig_py_bool_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_bytes_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_capsule_check_exact(obj: *PyObject) c_int;
pub extern "c" fn zig_py_coro_check_exact(obj: *PyObject) c_int;
pub extern "c" fn zig_py_dict_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_float_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_list_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_long_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_tuple_check(obj: *PyObject) c_int;
pub extern "c" fn zig_py_unicode_check(obj: *PyObject) c_int;

// Object operations
pub extern "c" fn PyObject_IsTrue(obj: *PyObject) c_int;

// Bytes operations
pub extern "c" fn PyBytes_AsStringAndSize(obj: *PyObject, buffer: *[*c]u8, length: *c_long) c_int;

// Capsule operations
pub extern "c" fn PyCapsule_New(pointer: ?*anyopaque, name: [*c]const u8, destructor: ?*const fn (?*anyopaque) callconv(.C) void) ?*PyObject;
pub extern "c" fn PyCapsule_GetPointer(capsule: *PyObject, name: [*c]const u8) ?*anyopaque;

// Python constants - custom accessor functions
pub extern "c" fn zig_get_py_none() *PyObject;
pub extern "c" fn zig_get_py_true() *PyObject;
pub extern "c" fn zig_get_py_false() *PyObject;
pub extern "c" fn zig_call_function_with_arg(*PyObject, *PyObject) ?*PyObject;
pub extern "c" fn zig_is_py_none(*PyObject) c_int;

// Exception objects
pub extern "c" var PyExc_RuntimeError: *PyObject;
pub extern "c" var PyExc_TypeError: *PyObject;
pub extern "c" var PyExc_ImportError: *PyObject;
pub extern "c" var PyExc_AttributeError: *PyObject;
pub extern "c" var PyExc_ValueError: *PyObject;

// Thread state functions
pub extern "c" fn PyEval_SaveThread() ?*anyopaque;
pub extern "c" fn PyEval_RestoreThread(?*anyopaque) void;

// Method definitions and function pointers
pub extern "c" fn PyCFunction_New(*const PyMethodDef, ?*PyObject) ?*PyObject;

// Helper functions with more convenient names
pub fn getPyNone() *PyObject {
    return zig_get_py_none();
}

pub fn getPyTrue() *PyObject {
    return zig_get_py_true();
}

pub fn getPyFalse() *PyObject {
    return zig_get_py_false();
}

pub fn incref(obj: *PyObject) void {
    zig_py_incref(obj);
}

pub fn decref(obj: *PyObject) void {
    zig_py_decref(obj);
}

pub fn isNone(obj: *PyObject) bool {
    return zig_is_py_none(obj) != 0;
}

// Convenience type-checking functions
pub fn PyBool_Check(obj: *PyObject) c_int {
    return zig_py_bool_check(obj);
}

pub fn PyBytes_Check(obj: *PyObject) c_int {
    return zig_py_bytes_check(obj);
}

pub fn PyCapsule_CheckExact(obj: *PyObject) c_int {
    return zig_py_capsule_check_exact(obj);
}

pub fn PyCoro_CheckExact(obj: *PyObject) c_int {
    return zig_py_coro_check_exact(obj);
}

pub fn PyDict_Check(obj: *PyObject) c_int {
    return zig_py_dict_check(obj);
}

pub fn PyFloat_Check(obj: *PyObject) c_int {
    return zig_py_float_check(obj);
}

pub fn PyList_Check(obj: *PyObject) c_int {
    return zig_py_list_check(obj);
}

pub fn PyLong_Check(obj: *PyObject) c_int {
    return zig_py_long_check(obj);
}

pub fn PyTuple_Check(obj: *PyObject) c_int {
    return zig_py_tuple_check(obj);
}

pub fn PyUnicode_Check(obj: *PyObject) c_int {
    return zig_py_unicode_check(obj);
}
