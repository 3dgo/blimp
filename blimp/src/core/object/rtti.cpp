#include "../core.h"
#include "rtti.h"
#include "object.h"

namespace blimp
{

    std::map<STRCODE, Rtti *> *Rtti::rtti_class_table;

    Rtti::Rtti(std::string class_name, std::function<Object *()> ctor)
    {
        rtti_class_name = class_name;
        rtti_class_hash = get_str_code(class_name.c_str());
        rtti_ctor = ctor;
        register_class();
    };

    Rtti Rtti::get_rtti(const std::string &class_name)
    {
        Rtti *rtti = Rtti::find_rtti_class(class_name);
        return *rtti;
    }

    Object *create_object(const std::string &class_name)
    {
        return Rtti::construct_object(class_name);
    };

    Object *Rtti::construct_object() const
    {
        return rtti_ctor ? rtti_ctor() : nullptr;
    };

    Object *Rtti::construct_object(const std::string &class_name)
    {
        return Rtti::construct_object(get_str_code(class_name.c_str()));
    };

    Object *Rtti::construct_object(const STRCODE class_strcode)
    {
        Rtti *rtti = Rtti::find_rtti_class(class_strcode);
        assert(rtti);
        assert(rtti->has_constructor());

        Object *obj = rtti->construct_object();
        return obj;
    };

    Rtti *Rtti::find_rtti_class(const std::string &class_name)
    {
        return find_rtti_class(get_str_code(class_name.c_str()));
    };

    Rtti *Rtti::find_rtti_class(const STRCODE class_code)
    {
        if (rtti_class_table == nullptr)
        {
            return nullptr;
        }

        std::map<STRCODE, Rtti *>::iterator item = rtti_class_table->find(class_code);
        if (item == rtti_class_table->end())
        {
            assert(0);
        }

        return (*item).second;
    };

}