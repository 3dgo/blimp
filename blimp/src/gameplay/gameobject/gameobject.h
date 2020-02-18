//
// Created by lucien on 2/16/20.
//
#pragma once

class Component;

namespace blimp
{
    class GameObject : public Object
    {
    DECLARE_DYNAMIC_DERIVED_CLASS(GameObject, Object)

    public:
        GameObject();
        ~GameObject();


    private:
        std::map<STRCODE, std::shared_ptr<Component>> components;

    };

}

