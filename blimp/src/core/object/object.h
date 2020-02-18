#pragma once

// Operator Overloads and uuid implemented by Matt Warner
/// <summary>
/// Object Class
/// </summary>

namespace blimp
{
    class Object
    {
    DECLARE_ABSTRACT_BASE_CLASS(Object)

    private:
        std::string name = "";
        UUID uuid = "";			    // holds the uuid struct
        STRCODE uuid_strcode = 0;		// holds the uuid hashCode used for comparisions

    public:
        Object();
        virtual ~Object();


        virtual void initialize();
        virtual void destroy();

        const std::string& get_name() const { return name; }
        STRCODE get_uuid_strcode() const { return uuid_strcode; }

        bool operator==(const Object& rhs) const
        {
            return uuid_strcode == rhs.get_uuid_strcode();
        }
        bool operator!=(const Object& rhs) const
        {
            return uuid_strcode == rhs.get_uuid_strcode();
        }

        bool operator<(const Object& rhs) const
        {
            return uuid_strcode < rhs.get_uuid_strcode();
        }

        bool operator<=(const Object& rhs) const
        {
            return uuid_strcode <= rhs.get_uuid_strcode();
        }

        bool operator>(const Object& rhs) const
        {
            return uuid_strcode > rhs.get_uuid_strcode();
        }

        bool operator>=(const Object& rhs) const
        {
            return uuid_strcode >= rhs.get_uuid_strcode();
        }
    };

}

