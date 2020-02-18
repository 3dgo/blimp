#include "../core.h"
#include "object.h"

namespace blimp
{
    IMPLEMENT_ABSTRACT_CLASS(Object)

    Object::Object()
            : 	uuid(),
                 uuid_strcode(0)
    {
    }

    Object::~Object()
    {
    }

    void Object::initialize()
    {

    }

    void Object::destroy()
    {

    }
}
